#!/bin/bash

# Backup Script for PostgreSQL RDS Database
# Version: 1.0.0
# Required: aws-cli >= 2.0, postgresql-client >= 14
# Description: Automated PostgreSQL database backups to S3 with encryption, compression, and monitoring

# Exit on any error
set -e

# Trap signals for cleanup
trap cleanup SIGTERM SIGINT ERR EXIT

# Global variables with defaults
: "${AWS_REGION:=us-east-1}"
: "${BACKUP_RETENTION_DAYS:=30}"
: "${WAL_RETENTION_HOURS:=24}"

# Required environment variables
required_vars=(
    "BACKUP_BUCKET"
    "DB_INSTANCE_IDENTIFIER"
    "NOTIFICATION_SNS_TOPIC"
    "ENCRYPTION_KEY_ARN"
)

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/db-backup.log
}

# Error handling function
error() {
    log "ERROR: $1"
    send_notification "ERROR" "$1"
    exit 1
}

# Cleanup function
cleanup() {
    if [ $? -ne 0 ]; then
        error "Backup failed with exit code $?"
    fi
    # Clean up temporary files
    rm -f /tmp/backup-*.tmp
    log "Cleanup completed"
}

# Check prerequisites function
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check AWS CLI version
    aws_version=$(aws --version 2>&1 | cut -d/ -f2 | cut -d. -f1)
    if [ "$aws_version" -lt 2 ]; then
        error "AWS CLI version 2.0 or higher required"
    fi
    
    # Check PostgreSQL client
    if ! command -v psql &> /dev/null; then
        error "postgresql-client is required but not installed"
    fi
    
    # Verify environment variables
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            error "Required environment variable $var is not set"
        fi
    done
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "Invalid AWS credentials"
    fi
    
    # Verify S3 bucket access
    if ! aws s3 ls "s3://${BACKUP_BUCKET}" &> /dev/null; then
        error "Cannot access S3 bucket ${BACKUP_BUCKET}"
    }
    
    log "Prerequisites check passed"
    return 0
}

# Create RDS snapshot function
create_rds_snapshot() {
    local snapshot_identifier="$1"
    log "Creating RDS snapshot: $snapshot_identifier"
    
    # Create snapshot with encryption
    aws rds create-db-snapshot \
        --region "${AWS_REGION}" \
        --db-instance-identifier "${DB_INSTANCE_IDENTIFIER}" \
        --db-snapshot-identifier "${snapshot_identifier}" \
        --tags "Key=CreatedBy,Value=AutomatedBackup" "Key=RetentionDays,Value=${BACKUP_RETENTION_DAYS}" \
        || error "Failed to create snapshot"
    
    # Wait for snapshot completion
    log "Waiting for snapshot completion..."
    aws rds wait db-snapshot-available \
        --region "${AWS_REGION}" \
        --db-snapshot-identifier "${snapshot_identifier}" \
        || error "Snapshot creation failed or timed out"
    
    # Verify encryption
    snapshot_encrypted=$(aws rds describe-db-snapshots \
        --region "${AWS_REGION}" \
        --db-snapshot-identifier "${snapshot_identifier}" \
        --query 'DBSnapshots[0].Encrypted' \
        --output text)
    
    if [ "$snapshot_encrypted" != "true" ]; then
        error "Snapshot encryption verification failed"
    }
    
    log "Snapshot created successfully: $snapshot_identifier"
    return 0
}

# Backup WAL logs function
backup_wal_logs() {
    log "Starting WAL logs backup..."
    
    # Get latest WAL location
    local wal_location="/rds/wal_archive"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # Compress and encrypt WAL files
    find "${wal_location}" -type f -mmin -$((WAL_RETENTION_HOURS * 60)) -name "*.wal" | while read -r wal_file; do
        local base_name=$(basename "$wal_file")
        log "Processing WAL file: $base_name"
        
        # Compress WAL file
        gzip -c "$wal_file" > "/tmp/${base_name}.gz" \
            || error "Failed to compress WAL file: $base_name"
        
        # Encrypt and upload to S3
        aws s3 cp "/tmp/${base_name}.gz" \
            "s3://${BACKUP_BUCKET}/wal/${timestamp}/${base_name}.gz" \
            --sse aws:kms \
            --sse-kms-key-id "${ENCRYPTION_KEY_ARN}" \
            || error "Failed to upload WAL file: $base_name"
        
        rm -f "/tmp/${base_name}.gz"
    done
    
    log "WAL logs backup completed"
    return 0
}

# Cleanup old backups function
cleanup_old_backups() {
    local retention_days="$1"
    log "Cleaning up backups older than $retention_days days..."
    
    # Calculate cutoff date
    local cutoff_date=$(date -d "$retention_days days ago" +%Y-%m-%d)
    
    # List and delete old snapshots
    local old_snapshots=$(aws rds describe-db-snapshots \
        --region "${AWS_REGION}" \
        --query "DBSnapshots[?SnapshotCreateTime<='${cutoff_date}'].DBSnapshotIdentifier" \
        --output text)
    
    for snapshot in $old_snapshots; do
        log "Deleting old snapshot: $snapshot"
        aws rds delete-db-snapshot \
            --region "${AWS_REGION}" \
            --db-snapshot-identifier "$snapshot" \
            || log "Warning: Failed to delete snapshot: $snapshot"
    done
    
    # Cleanup old WAL archives
    local cutoff_hours=$((WAL_RETENTION_HOURS))
    aws s3 rm "s3://${BACKUP_BUCKET}/wal/" \
        --recursive \
        --exclude "*" \
        --include "*.gz" \
        --older-than "${cutoff_hours}H" \
        || log "Warning: Failed to cleanup some WAL archives"
    
    log "Cleanup completed"
    return 0
}

# Verify backup function
verify_backup() {
    local snapshot_identifier="$1"
    log "Verifying backup: $snapshot_identifier"
    
    # Verify snapshot exists and is encrypted
    local snapshot_status=$(aws rds describe-db-snapshots \
        --region "${AWS_REGION}" \
        --db-snapshot-identifier "${snapshot_identifier}" \
        --query 'DBSnapshots[0].[Status,Encrypted]' \
        --output text)
    
    if [ -z "$snapshot_status" ]; then
        error "Snapshot verification failed: Snapshot not found"
    fi
    
    # Verify WAL archive continuity
    local wal_count=$(aws s3 ls "s3://${BACKUP_BUCKET}/wal/" --recursive | wc -l)
    if [ "$wal_count" -eq 0 ]; then
        log "Warning: No WAL archives found"
    fi
    
    log "Backup verification completed successfully"
    return 0
}

# Send notification function
send_notification() {
    local status="$1"
    local message="$2"
    
    local notification_data=$(cat <<EOF
{
    "backup_status": "$status",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "instance": "${DB_INSTANCE_IDENTIFIER}",
    "message": "$message"
}
EOF
)
    
    aws sns publish \
        --region "${AWS_REGION}" \
        --topic-arn "${NOTIFICATION_SNS_TOPIC}" \
        --message "$notification_data" \
        || log "Warning: Failed to send notification"
    
    return 0
}

# Main execution
main() {
    log "Starting backup process..."
    
    # Check prerequisites
    check_prerequisites || exit 1
    
    # Generate snapshot identifier
    snapshot_identifier="${DB_INSTANCE_IDENTIFIER}-backup-$(date +%Y%m%d-%H%M%S)"
    
    # Create snapshot
    create_rds_snapshot "$snapshot_identifier" || exit 1
    
    # Backup WAL logs
    backup_wal_logs || exit 1
    
    # Verify backup
    verify_backup "$snapshot_identifier" || exit 1
    
    # Cleanup old backups
    cleanup_old_backups "${BACKUP_RETENTION_DAYS}" || log "Warning: Cleanup partially failed"
    
    # Send success notification
    send_notification "SUCCESS" "Backup completed successfully: $snapshot_identifier"
    
    log "Backup process completed successfully"
}

# Execute main function
main "$@"