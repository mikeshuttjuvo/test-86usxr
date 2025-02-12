#!/bin/bash

# Deployment Script for Rails API Service
# Version: 1.0.0
# Dependencies:
# - aws-cli 2.0+
# - jq 1.6+
# - docker 20.10+

set -euo pipefail

# Source required scripts
SCRIPT_DIR="$(dirname "$0")"
source "${SCRIPT_DIR}/health-check.sh"
source "${SCRIPT_DIR}/rollback.sh"

# Global Variables
AWS_REGION=${AWS_REGION:-us-east-1}
DEPLOY_ENV=${DEPLOY_ENV:-production}
ECR_REPOSITORY=${ECR_REPOSITORY:-rails-api}
ECS_CLUSTER=${ECS_CLUSTER:-rails-api-cluster}
ECS_SERVICE=${ECS_SERVICE:-rails-api-service}
TASK_FAMILY=${TASK_FAMILY:-rails-api-task}
RAILS_ENV=${RAILS_ENV:-production}

# Deployment Configuration
DEPLOY_TIMEOUT=900
HEALTH_CHECK_RETRIES=5
TRAFFIC_SHIFT_STEP=10
DEPLOYMENT_MARKER="/tmp/deployment_in_progress"
LOG_FILE="/var/log/deployment.log"

# Logging setup
log() {
    local level=$1
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${LOG_FILE}"
}

error() {
    log "ERROR" "$@"
    return 1
}

# Validate deployment prerequisites
validate_prerequisites() {
    log "INFO" "Validating deployment prerequisites..."

    # Check for concurrent deployment
    if [ -f "${DEPLOYMENT_MARKER}" ]; then
        error "Another deployment is in progress"
        return 1
    fi

    # Verify required environment variables
    for var in AWS_REGION DEPLOY_ENV ECR_REPOSITORY ECS_CLUSTER ECS_SERVICE TASK_FAMILY RAILS_ENV; do
        if [ -z "${!var}" ]; then
            error "Required environment variable ${var} is not set"
            return 1
        fi
    done

    # Check required tools
    for cmd in aws jq docker; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            error "${cmd} is not installed"
            return 1
        fi
    done

    # Verify AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "Invalid AWS credentials"
        return 1
    fi

    # Create deployment marker
    touch "${DEPLOYMENT_MARKER}"
    log "INFO" "Prerequisites validation completed successfully"
    return 0
}

# Register new task definition
register_task_definition() {
    local image_tag=$1
    log "INFO" "Registering new task definition with image tag: ${image_tag}"

    # Get current task definition
    local current_task_def
    current_task_def=$(aws ecs describe-task-definition \
        --task-definition "${TASK_FAMILY}" \
        --region "${AWS_REGION}" \
        --query 'taskDefinition' \
        --output json)

    # Update container image and environment
    local new_task_def
    new_task_def=$(echo "${current_task_def}" | jq --arg IMAGE "${ECR_REPOSITORY}:${image_tag}" \
        --arg ENV "${RAILS_ENV}" \
        --arg TIMESTAMP "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '.containerDefinitions[0].image = $IMAGE |
        .containerDefinitions[0].environment += [
            {"name": "RAILS_ENV", "value": $ENV},
            {"name": "DEPLOYMENT_TIMESTAMP", "value": $TIMESTAMP}
        ]')

    # Register new task definition
    local task_def_arn
    task_def_arn=$(aws ecs register-task-definition \
        --family "${TASK_FAMILY}" \
        --container-definitions "${new_task_def}" \
        --task-role-arn "$(echo "${current_task_def}" | jq -r '.taskRoleArn')" \
        --execution-role-arn "$(echo "${current_task_def}" | jq -r '.executionRoleArn')" \
        --network-mode "$(echo "${current_task_def}" | jq -r '.networkMode')" \
        --region "${AWS_REGION}" \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)

    echo "${task_def_arn}"
}

# Run database migrations
run_database_migrations() {
    local task_definition_arn=$1
    log "INFO" "Running database migrations..."

    # Create migration task
    local migration_task
    migration_task=$(aws ecs run-task \
        --cluster "${ECS_CLUSTER}" \
        --task-definition "${task_definition_arn}" \
        --network-configuration "$(aws ecs describe-services \
            --cluster "${ECS_CLUSTER}" \
            --services "${ECS_SERVICE}" \
            --query 'services[0].networkConfiguration' \
            --output json)" \
        --overrides '{
            "containerOverrides": [{
                "name": "rails-api",
                "command": ["bundle", "exec", "rake", "db:migrate"]
            }]
        }' \
        --region "${AWS_REGION}" \
        --query 'tasks[0].taskArn' \
        --output text)

    # Wait for migration completion
    if ! aws ecs wait tasks-stopped \
        --cluster "${ECS_CLUSTER}" \
        --tasks "${migration_task}" \
        --region "${AWS_REGION}"; then
        error "Database migration failed"
        return 1
    fi

    # Verify migration success
    local exit_code
    exit_code=$(aws ecs describe-tasks \
        --cluster "${ECS_CLUSTER}" \
        --tasks "${migration_task}" \
        --query 'tasks[0].containers[0].exitCode' \
        --output text)

    if [ "${exit_code}" -ne 0 ]; then
        error "Migration task failed with exit code ${exit_code}"
        return 1
    fi

    log "INFO" "Database migrations completed successfully"
    return 0
}

# Update ECS service with blue-green deployment
update_service() {
    local task_definition_arn=$1
    log "INFO" "Updating service with blue-green deployment..."

    # Configure deployment settings
    local deployment_config
    deployment_config=$(aws ecs update-service \
        --cluster "${ECS_CLUSTER}" \
        --service "${ECS_SERVICE}" \
        --task-definition "${task_definition_arn}" \
        --deployment-configuration '{
            "deploymentCircuitBreaker": {
                "enable": true,
                "rollback": true
            },
            "maximumPercent": 200,
            "minimumHealthyPercent": 100
        }' \
        --region "${AWS_REGION}")

    # Monitor deployment progress
    local timeout_counter=0
    local deployment_completed=false
    while [ $timeout_counter -lt $DEPLOY_TIMEOUT ]; do
        local deployment_status
        deployment_status=$(aws ecs describe-services \
            --cluster "${ECS_CLUSTER}" \
            --services "${ECS_SERVICE}" \
            --region "${AWS_REGION}" \
            --query 'services[0].deployments[0].status' \
            --output text)

        if [ "${deployment_status}" = "PRIMARY" ]; then
            deployment_completed=true
            break
        fi

        sleep 10
        timeout_counter=$((timeout_counter + 10))
        log "INFO" "Waiting for deployment... ${timeout_counter}/${DEPLOY_TIMEOUT} seconds"
    done

    if [ "${deployment_completed}" = false ]; then
        error "Deployment timed out after ${DEPLOY_TIMEOUT} seconds"
        return 1
    fi

    log "INFO" "Service updated successfully"
    return 0
}

# Verify deployment success
verify_deployment() {
    log "INFO" "Verifying deployment..."
    local retry_count=0

    while [ $retry_count -lt $HEALTH_CHECK_RETRIES ]; do
        if check_application_health; then
            log "INFO" "Deployment verification successful"
            return 0
        fi

        retry_count=$((retry_count + 1))
        log "WARN" "Health check failed, retrying... ${retry_count}/${HEALTH_CHECK_RETRIES}"
        sleep 30
    done

    error "Deployment verification failed after ${HEALTH_CHECK_RETRIES} attempts"
    return 1
}

# Cleanup deployment resources
cleanup_deployment() {
    log "INFO" "Cleaning up deployment resources..."

    # Remove deployment marker
    rm -f "${DEPLOYMENT_MARKER}"

    # Archive deployment logs
    local archive_dir="/var/log/deployment_archive"
    mkdir -p "${archive_dir}"
    cp "${LOG_FILE}" "${archive_dir}/deploy_$(date +'%Y%m%d_%H%M%S').log"

    # Deregister old task definitions
    local task_definitions
    task_definitions=$(aws ecs list-task-definitions \
        --family-prefix "${TASK_FAMILY}" \
        --sort DESC \
        --region "${AWS_REGION}" \
        --query 'taskDefinitionArns[2:]' \
        --output json)

    echo "${task_definitions}" | jq -r '.[]' | while read -r task_def; do
        aws ecs deregister-task-definition \
            --task-definition "${task_def}" \
            --region "${AWS_REGION}" >/dev/null
    done

    log "INFO" "Cleanup completed successfully"
    return 0
}

# Main deployment function
main() {
    local image_tag=$1
    log "INFO" "Starting deployment for ${DEPLOY_ENV} environment with image tag: ${image_tag}"

    # Initialize error tracking
    local exit_code=0

    # Execute deployment steps
    if ! validate_prerequisites; then
        error "Failed to validate prerequisites"
        exit_code=1
    else
        local task_definition_arn
        if task_definition_arn=$(register_task_definition "${image_tag}"); then
            if run_database_migrations "${task_definition_arn}" && \
               update_service "${task_definition_arn}" && \
               verify_deployment; then
                log "INFO" "Deployment completed successfully"
            else
                error "Deployment failed"
                perform_rollback
                exit_code=1
            fi
        else
            error "Failed to register task definition"
            exit_code=1
        fi
    fi

    # Cleanup regardless of success/failure
    cleanup_deployment

    if [ $exit_code -eq 0 ]; then
        log "INFO" "Deployment operation completed successfully"
    else
        log "ERROR" "Deployment operation failed"
    fi

    return $exit_code
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -ne 1 ]; then
        error "Usage: $0 <image_tag>"
        exit 1
    fi
    main "$1"
fi