#!/bin/bash

# Rollback Script for ECS Deployments
# Version: 1.0.0
# Dependencies:
# - aws-cli 2.0+
# - jq 1.6+
# - docker 20.10+

set -euo pipefail

# Source health check functions
source "$(dirname "$0")/health-check.sh"

# Global Variables
AWS_REGION=${AWS_REGION:-us-east-1}
DEPLOY_ENV=${DEPLOY_ENV:-production}
ECR_REPOSITORY=${ECR_REPOSITORY:-rails-api}
ECS_CLUSTER=${ECS_CLUSTER:-rails-api-cluster}
ECS_SERVICE=${ECS_SERVICE:-rails-api-service}
TASK_FAMILY=${TASK_FAMILY:-rails-api-task}
ROLLBACK_MARKER="/tmp/rollback_in_progress"
LOG_FILE="/var/log/rollback.log"
HEALTH_CHECK_TIMEOUT=300

# Logging setup
log() {
    local level=$1
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR" "$@"
    return 1
}

# Validate rollback prerequisites
validate_rollback_prerequisites() {
    log "INFO" "Validating rollback prerequisites..."

    # Check required environment variables
    for var in AWS_REGION DEPLOY_ENV ECR_REPOSITORY ECS_CLUSTER ECS_SERVICE TASK_FAMILY; do
        if [ -z "${!var}" ]; then
            error "Required environment variable $var is not set"
            return 1
        fi
    done

    # Check for concurrent rollback
    if [ -f "$ROLLBACK_MARKER" ]; then
        error "Another rollback operation is in progress"
        return 1
    fi

    # Verify AWS CLI installation
    if ! command -v aws >/dev/null 2>&1; then
        error "AWS CLI is not installed"
        return 1
    fi

    # Verify jq installation
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is not installed"
        return 1
    }

    # Create rollback marker
    touch "$ROLLBACK_MARKER"
    log "INFO" "Prerequisites validation completed successfully"
    return 0
}

# Get previous stable task definition
get_previous_task_definition() {
    log "INFO" "Retrieving previous stable task definition..."

    local current_task_def
    current_task_def=$(aws ecs describe-services \
        --cluster "$ECS_CLUSTER" \
        --services "$ECS_SERVICE" \
        --region "$AWS_REGION" \
        --query 'services[0].taskDefinition' \
        --output text)

    local previous_task_def
    previous_task_def=$(aws ecs list-task-definitions \
        --family-prefix "$TASK_FAMILY" \
        --sort DESC \
        --region "$AWS_REGION" \
        --query 'taskDefinitionArns[1]' \
        --output text)

    if [ -z "$previous_task_def" ] || [ "$previous_task_def" = "null" ]; then
        error "No previous task definition found"
        return 1
    }

    log "INFO" "Previous stable task definition: $previous_task_def"
    echo "$previous_task_def"
}

# Revert database migrations
revert_database_migrations() {
    local previous_task_def=$1
    log "INFO" "Reverting database migrations..."

    # Create migration task
    local migration_task
    migration_task=$(aws ecs run-task \
        --cluster "$ECS_CLUSTER" \
        --task-definition "$previous_task_def" \
        --network-configuration "$(aws ecs describe-services \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE" \
            --query 'services[0].networkConfiguration' \
            --output json)" \
        --overrides '{
            "containerOverrides": [{
                "name": "rails-api",
                "command": ["bundle", "exec", "rake", "db:rollback"]
            }]
        }' \
        --region "$AWS_REGION" \
        --query 'tasks[0].taskArn' \
        --output text)

    # Wait for migration completion
    if ! aws ecs wait tasks-stopped \
        --cluster "$ECS_CLUSTER" \
        --tasks "$migration_task" \
        --region "$AWS_REGION"; then
        error "Database migration rollback failed"
        return 1
    }

    log "INFO" "Database migrations reverted successfully"
    return 0
}

# Rollback service with zero-downtime
rollback_service() {
    local previous_task_def=$1
    log "INFO" "Rolling back service to previous version..."

    # Update service with previous task definition
    if ! aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$ECS_SERVICE" \
        --task-definition "$previous_task_def" \
        --region "$AWS_REGION" \
        --force-new-deployment; then
        error "Service update failed"
        return 1
    }

    # Wait for service stability
    log "INFO" "Waiting for service stability..."
    if ! aws ecs wait services-stable \
        --cluster "$ECS_CLUSTER" \
        --services "$ECS_SERVICE" \
        --region "$AWS_REGION"; then
        error "Service failed to stabilize"
        return 1
    }

    log "INFO" "Service rolled back successfully"
    return 0
}

# Verify rollback success
verify_rollback() {
    log "INFO" "Verifying rollback..."
    local timeout_counter=0
    local max_attempts=$((HEALTH_CHECK_TIMEOUT / 10))

    while [ $timeout_counter -lt $max_attempts ]; do
        if check_application_health && check_database_connectivity; then
            log "INFO" "Rollback verification successful"
            return 0
        fi
        
        sleep 10
        timeout_counter=$((timeout_counter + 1))
        log "INFO" "Waiting for health check... Attempt $timeout_counter of $max_attempts"
    done

    error "Rollback verification failed after $HEALTH_CHECK_TIMEOUT seconds"
    return 1
}

# Cleanup rollback resources
cleanup_rollback() {
    log "INFO" "Cleaning up rollback resources..."

    # Remove rollback marker
    rm -f "$ROLLBACK_MARKER"

    # Archive logs
    local archive_name="rollback_$(date +'%Y%m%d_%H%M%S').log"
    cp "$LOG_FILE" "/var/log/rollback_archive/$archive_name"

    log "INFO" "Cleanup completed successfully"
    return 0
}

# Main rollback function
perform_rollback() {
    log "INFO" "Starting rollback operation for $DEPLOY_ENV environment"

    # Initialize error tracking
    local exit_code=0

    # Execute rollback steps
    if ! validate_rollback_prerequisites; then
        error "Failed to validate prerequisites"
        exit_code=1
    else
        local previous_task_def
        if previous_task_def=$(get_previous_task_definition); then
            if revert_database_migrations "$previous_task_def" && \
               rollback_service "$previous_task_def" && \
               verify_rollback; then
                log "INFO" "Rollback completed successfully"
            else
                error "Rollback failed"
                exit_code=1
            fi
        else
            error "Failed to get previous task definition"
            exit_code=1
        fi
    fi

    # Cleanup regardless of success/failure
    cleanup_rollback

    if [ $exit_code -eq 0 ]; then
        log "INFO" "Rollback operation completed successfully"
    else
        log "ERROR" "Rollback operation failed"
    fi

    return $exit_code
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    perform_rollback "$@"
fi