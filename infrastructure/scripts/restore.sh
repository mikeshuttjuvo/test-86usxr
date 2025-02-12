#!/bin/bash

# Database Restore Script for Rails API Service
# Version: 1.0.0
# Dependencies:
# - aws-cli 2.0+
# - postgresql-client 14

set -euo pipefail

# Source health check functions
source "$(dirname "$0")/health-check.sh"

# Global Variables
readonly SCRIPT_VERSION="1.0.0"
readonly REQUIRED_AWS_CLI_VERSION="2.0"
readonly REQUIRED_PG_VERSION="14"
readonly RESTORE_LOG_FILE="/var/log/db-restore.log"
readonly TEMP_RESTORE_DIR="/tmp/db-restore"
readonly LOCK_FILE="/tmp/db-restore.lock"
readonly MAX_RETRY_ATTEMPTS=3
readonly RETRY_DELAY=30

# Ensure required environment variables
: "${AWS_REGION:?Must be set}"
: "${BACKUP_BUCKET:?Must be set}"
: "${DB_INSTANCE_IDENTIFIER:?Must be set}"
: "${NOTIFICATION_SNS_TOPIC:?Must be set}"

# Initialize logging
setup_restore_logging() {
    exec 1> >(tee -a "${RESTORE_LOG_FILE}") 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Database restore script v${SCRIPT_VERSION} initialized"
}

# Check prerequisites
check_prerequisites() {
    local exit_code=0

    # Check AWS CLI version
    local aws_version
    aws_version=$(aws --version 2>&1 | cut -d/ -f2 | cut -d. -f1)
    if [[ ${aws_version} -lt ${REQUIRED_AWS_CLI_VERSION} ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] AWS CLI version ${REQUIRED_AWS_CLI_VERSION}+ required"
        exit_code=1
    fi

    # Check PostgreSQL client version
    local pg_version
    pg_version=$(psql --version | awk '{print $3}' | cut -d. -f1)
    if [[ ${pg_version} != "${REQUIRED_PG_VERSION}" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] PostgreSQL client version ${REQUIRED_PG_VERSION} required"
        exit_code=1
    fi

    # Verify AWS credentials and permissions
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Invalid AWS credentials or insufficient permissions"
        exit_code=1
    fi

    # Check S3 bucket access
    if ! aws s3 ls "s3://${BACKUP_BUCKET}" &>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Cannot access S3 bucket: ${BACKUP_BUCKET}"
        exit_code=1
    fi

    # Create temporary directory
    mkdir -p "${TEMP_RESTORE_DIR}"

    return ${exit_code}
}

# List available backups
list_available_backups() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Listing available backups..."

    # List RDS snapshots
    aws rds describe-db-snapshots \
        --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}" \
        --snapshot-type automated \
        --query 'DBSnapshots[*].[DBSnapshotIdentifier,SnapshotCreateTime,Encrypted]' \
        --output table

    # List WAL archives
    aws s3 ls "s3://${BACKUP_BUCKET}/wal-archives/" \
        --recursive \
        --human-readable \
        --summarize
}

# Validate backup integrity
validate_backup() {
    local backup_identifier=$1
    local exit_code=0

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Validating backup: ${backup_identifier}"

    # Check snapshot status
    local snapshot_status
    snapshot_status=$(aws rds describe-db-snapshots \
        --db-snapshot-identifier "${backup_identifier}" \
        --query 'DBSnapshots[0].Status' \
        --output text)

    if [[ "${snapshot_status}" != "available" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Snapshot ${backup_identifier} is not available"
        return 1
    fi

    # Verify encryption
    local encryption_status
    encryption_status=$(aws rds describe-db-snapshots \
        --db-snapshot-identifier "${backup_identifier}" \
        --query 'DBSnapshots[0].Encrypted' \
        --output text)

    if [[ "${encryption_status}" != "true" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Snapshot ${backup_identifier} is not encrypted"
        return 1
    fi

    return ${exit_code}
}

# Restore from snapshot
restore_from_snapshot() {
    local snapshot_identifier=$1
    local temp_instance_identifier="${DB_INSTANCE_IDENTIFIER}-restore"
    local exit_code=0

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Starting restore from snapshot: ${snapshot_identifier}"

    # Create new instance from snapshot
    aws rds restore-db-instance-from-db-snapshot \
        --db-instance-identifier "${temp_instance_identifier}" \
        --db-snapshot-identifier "${snapshot_identifier}" \
        --db-instance-class "db.r5.large" \
        --no-publicly-accessible \
        --tags "Key=Environment,Value=production" "Key=Purpose,Value=restore"

    # Wait for instance to be available
    aws rds wait db-instance-available \
        --db-instance-identifier "${temp_instance_identifier}"

    # Verify restored instance
    if ! verify_restore "${temp_instance_identifier}"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Restore verification failed"
        exit_code=1
    fi

    return ${exit_code}
}

# Point-in-time recovery
restore_point_in_time() {
    local target_timestamp=$1
    local exit_code=0

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Starting point-in-time recovery to: ${target_timestamp}"

    # Create new instance with point-in-time recovery
    aws rds restore-db-instance-to-point-in-time \
        --source-db-instance-identifier "${DB_INSTANCE_IDENTIFIER}" \
        --target-db-instance-identifier "${DB_INSTANCE_IDENTIFIER}-pitr" \
        --restore-time "${target_timestamp}" \
        --no-publicly-accessible

    # Wait for restore to complete
    aws rds wait db-instance-available \
        --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}-pitr"

    return ${exit_code}
}

# Verify restore
verify_restore() {
    local instance_identifier=$1
    local exit_code=0

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Verifying restored instance: ${instance_identifier}"

    # Get instance endpoint
    local endpoint
    endpoint=$(aws rds describe-db-instances \
        --db-instance-identifier "${instance_identifier}" \
        --query 'DBInstances[0].Endpoint.Address' \
        --output text)

    # Check database connectivity
    if ! check_database_connectivity "https://${endpoint}"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Database connectivity check failed"
        exit_code=1
    fi

    return ${exit_code}
}

# Send notification
send_notification() {
    local status=$1
    local message=$2

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Sending notification: ${status} - ${message}"

    aws sns publish \
        --topic-arn "${NOTIFICATION_SNS_TOPIC}" \
        --message "Database Restore ${status}: ${message}" \
        --subject "Database Restore Notification" \
        --message-attributes "Status={DataType=String,StringValue=${status}}"
}

# Cleanup function
cleanup() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Performing cleanup..."
    rm -rf "${TEMP_RESTORE_DIR}"
    rm -f "${LOCK_FILE}"
}

# Signal handler
handle_signal() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Received termination signal"
    send_notification "INTERRUPTED" "Restore process interrupted by signal"
    cleanup
    exit 1
}

# Main function
main() {
    local exit_code=0

    # Set up signal handlers
    trap handle_signal SIGTERM SIGINT

    # Check for existing restore
    if [ -f "${LOCK_FILE}" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Another restore process is running"
        exit 1
    fi

    # Create lock file
    touch "${LOCK_FILE}"

    # Initialize logging
    setup_restore_logging

    # Check prerequisites
    if ! check_prerequisites; then
        send_notification "FAILED" "Prerequisites check failed"
        cleanup
        exit 1
    fi

    # Process restore based on input
    if [ -n "${RESTORE_POINT_IN_TIME:-}" ]; then
        if ! restore_point_in_time "${RESTORE_POINT_IN_TIME}"; then
            exit_code=1
        fi
    else
        # List available backups and perform restore
        list_available_backups

        local latest_snapshot
        latest_snapshot=$(aws rds describe-db-snapshots \
            --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}" \
            --snapshot-type automated \
            --query 'DBSnapshots[0].DBSnapshotIdentifier' \
            --output text)

        if ! validate_backup "${latest_snapshot}"; then
            send_notification "FAILED" "Backup validation failed"
            exit_code=1
        elif ! restore_from_snapshot "${latest_snapshot}"; then
            send_notification "FAILED" "Restore process failed"
            exit_code=1
        fi
    fi

    # Send final notification
    if [ ${exit_code} -eq 0 ]; then
        send_notification "SUCCESS" "Database restore completed successfully"
    else
        send_notification "FAILED" "Database restore failed"
    fi

    # Cleanup
    cleanup

    return ${exit_code}
}

# Execute main function
main "$@"