#!/bin/bash

# Health Check Script for Rails API Service
# Version: 1.0.0
# Dependencies:
# - curl 7.0+
# - jq 1.6+
# - aws-cli 2.0+
# - syslog (latest)

set -euo pipefail

# Global Configuration
AWS_REGION=${AWS_REGION:-us-east-1}
ENVIRONMENT=${ENVIRONMENT:-production}
ECS_CLUSTER=${ECS_CLUSTER:-rails-api-cluster}
ECS_SERVICE=${ECS_SERVICE:-rails-api-service}
HEALTH_CHECK_TIMEOUT=5
MAX_RETRIES=3
ALERT_THRESHOLD=80
LOG_LEVEL=${LOG_LEVEL:-INFO}
METRIC_NAMESPACE="RailsAPI/HealthCheck"
CLOUDWATCH_RETENTION=30

# Logging setup
setup_logging() {
    exec 1> >(logger -s -t $(basename $0)) 2>&1
    
    case ${LOG_LEVEL} in
        DEBUG) log_level=7 ;;
        INFO)  log_level=6 ;;
        WARN)  log_level=4 ;;
        ERROR) log_level=3 ;;
        *)     log_level=6 ;;
    esac
    
    logger "Health check script initialized with log level: ${LOG_LEVEL}"
}

# Dependency check
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl jq aws logger; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        logger -p user.error "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

# Get application URL from ECS service discovery or environment variable
get_app_url() {
    if [ -n "${APP_URL:-}" ]; then
        if [[ "${APP_URL}" =~ ^https?:// ]]; then
            echo "${APP_URL}"
            return 0
        fi
        logger -p user.error "Invalid APP_URL format"
        return 1
    fi

    local service_url
    service_url=$(aws ecs describe-services \
        --cluster "${ECS_CLUSTER}" \
        --services "${ECS_SERVICE}" \
        --region "${AWS_REGION}" \
        --query 'services[0].loadBalancers[0].targetGroupArn' \
        --output text)

    if [ -z "${service_url}" ]; then
        logger -p user.error "Failed to retrieve service URL from ECS"
        return 1
    fi

    echo "https://${service_url}"
}

# Check API health with retries and metrics
check_api_health() {
    local endpoint_url=$1
    local retry_count=0
    local start_time
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        start_time=$(date +%s%N)
        
        response=$(curl -sS -w "\n%{http_code}" \
            --max-time "${HEALTH_CHECK_TIMEOUT}" \
            "${endpoint_url}/health" || echo "000")
        
        status_code=$(echo "$response" | tail -n1)
        response_body=$(echo "$response" | head -n-1)
        
        end_time=$(date +%s%N)
        response_time=$(( (end_time - start_time) / 1000000 ))

        if [ "$status_code" = "200" ]; then
            if echo "${response_body}" | jq -e . >/dev/null 2>&1; then
                send_metric "APIResponseTime" ${response_time} "Milliseconds"
                logger "API health check successful. Response time: ${response_time}ms"
                return 0
            fi
        fi

        retry_count=$((retry_count + 1))
        logger -p user.warning "API health check failed (attempt ${retry_count}/${MAX_RETRIES})"
        sleep 2
    done

    send_alert "API" "Health check failed after ${MAX_RETRIES} attempts" "CRITICAL"
    return 1
}

# Check database connectivity and performance
check_database_connectivity() {
    local endpoint_url=$1
    local start_time
    
    start_time=$(date +%s%N)
    response=$(curl -sS --max-time "${HEALTH_CHECK_TIMEOUT}" \
        "${endpoint_url}/health/database" || echo "")
    
    if [ -z "$response" ]; then
        send_alert "Database" "Connection check failed" "CRITICAL"
        return 1
    fi

    local db_status
    db_status=$(echo "${response}" | jq -r '.database.status')
    
    if [ "${db_status}" = "ok" ]; then
        local end_time=$(date +%s%N)
        local query_time=$(( (end_time - start_time) / 1000000 ))
        send_metric "DatabaseResponseTime" ${query_time} "Milliseconds"
        logger "Database health check successful. Response time: ${query_time}ms"
        return 0
    fi

    send_alert "Database" "Unhealthy database status: ${db_status}" "CRITICAL"
    return 1
}

# Check Redis connectivity and performance
check_redis_connectivity() {
    local endpoint_url=$1
    local start_time
    
    start_time=$(date +%s%N)
    response=$(curl -sS --max-time "${HEALTH_CHECK_TIMEOUT}" \
        "${endpoint_url}/health/redis" || echo "")
    
    if [ -z "$response" ]; then
        send_alert "Redis" "Connection check failed" "CRITICAL"
        return 1
    }

    local redis_status
    redis_status=$(echo "${response}" | jq -r '.redis.status')
    
    if [ "${redis_status}" = "ok" ]; then
        local end_time=$(date +%s%N)
        local response_time=$(( (end_time - start_time) / 1000000 ))
        send_metric "RedisResponseTime" ${response_time} "Milliseconds"
        logger "Redis health check successful. Response time: ${response_time}ms"
        return 0
    fi

    send_alert "Redis" "Unhealthy Redis status: ${redis_status}" "CRITICAL"
    return 1
}

# Check system resources
check_system_resources() {
    local cpu_usage
    local memory_usage
    local disk_usage
    
    cpu_usage=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/ECS \
        --metric-name CPUUtilization \
        --dimensions Name=ClusterName,Value="${ECS_CLUSTER}" Name=ServiceName,Value="${ECS_SERVICE}" \
        --start-time $(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ") \
        --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --period 300 \
        --statistics Average \
        --query 'Datapoints[0].Average' \
        --output text)

    if [ $(echo "${cpu_usage} > ${ALERT_THRESHOLD}" | bc -l) -eq 1 ]; then
        send_alert "System" "High CPU usage: ${cpu_usage}%" "WARNING"
    fi

    send_metric "CPUUtilization" ${cpu_usage} "Percent"
    logger "System resources check completed. CPU Usage: ${cpu_usage}%"
    return 0
}

# Send metrics to CloudWatch
send_metric() {
    local metric_name=$1
    local metric_value=$2
    local metric_unit=$3
    
    aws cloudwatch put-metric-data \
        --namespace "${METRIC_NAMESPACE}" \
        --metric-name "${metric_name}" \
        --value "${metric_value}" \
        --unit "${metric_unit}" \
        --dimensions Environment="${ENVIRONMENT}" \
        --region "${AWS_REGION}"
}

# Send alerts
send_alert() {
    local service_name=$1
    local error_message=$2
    local severity=$3
    
    logger -p user.error "[${severity}] ${service_name}: ${error_message}"
    
    aws cloudwatch put-metric-alarm \
        --alarm-name "${service_name}_Health_${severity}" \
        --alarm-description "${error_message}" \
        --metric-name "HealthCheckFailure" \
        --namespace "${METRIC_NAMESPACE}" \
        --statistic Sum \
        --period 60 \
        --threshold 1 \
        --comparison-operator GreaterThanThreshold \
        --evaluation-periods 1 \
        --alarm-actions "arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:${ENVIRONMENT}-alerts" \
        --region "${AWS_REGION}"
}

# Main function
main() {
    local exit_code=0
    
    setup_logging
    check_dependencies
    
    logger "Starting health check for ${ENVIRONMENT} environment"
    
    local app_url
    app_url=$(get_app_url) || exit 1
    
    # Execute health checks
    check_api_health "${app_url}" || exit_code=$((exit_code + 1))
    check_database_connectivity "${app_url}" || exit_code=$((exit_code + 1))
    check_redis_connectivity "${app_url}" || exit_code=$((exit_code + 1))
    check_system_resources || exit_code=$((exit_code + 1))
    
    if [ $exit_code -eq 0 ]; then
        logger "Health check completed successfully"
    else
        logger -p user.error "Health check completed with ${exit_code} failures"
    fi
    
    return $exit_code
}

# Execute main function
main "$@"