# AWS Provider version constraint
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# DB Subnet Group
resource "aws_db_subnet_group" "this" {
  name       = "${var.environment}-rds-subnet-group"
  subnet_ids = var.database_subnet_ids

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Service     = "rails-api"
  }
}

# DB Parameter Group optimized for Rails API workload
resource "aws_db_parameter_group" "this" {
  family = "postgres14"
  name   = "${var.environment}-postgres14-params"

  parameter {
    name  = "max_connections"
    value = "1000"
  }

  parameter {
    name  = "shared_buffers"
    value = "{DBInstanceClassMemory/32768}MB"
  }

  parameter {
    name  = "work_mem"
    value = "64MB"
  }

  parameter {
    name  = "maintenance_work_mem"
    value = "256MB"
  }

  parameter {
    name  = "effective_cache_size"
    value = "{DBInstanceClassMemory/16384}MB"
  }

  parameter {
    name  = "ssl"
    value = "1"
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Service     = "rails-api"
  }
}

# Primary RDS Instance
resource "aws_db_instance" "primary" {
  identifier = "${var.environment}-primary"
  
  # Engine Configuration
  engine         = "postgres"
  engine_version = var.engine_version
  
  # Instance Configuration
  instance_class = var.instance_class
  
  # Storage Configuration
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type         = "gp3"
  storage_encrypted    = true
  iops                 = 12000

  # Database Configuration
  db_name  = "rails_api_${var.environment}"
  username = var.master_username
  password = var.master_password

  # Network Configuration
  multi_az               = var.multi_az
  vpc_security_group_ids = var.security_group_ids
  db_subnet_group_name   = aws_db_subnet_group.this.name

  # Parameter and Option Groups
  parameter_group_name = aws_db_parameter_group.this.name

  # Backup Configuration
  backup_retention_period = var.backup_retention_period
  backup_window          = "03:00-04:00"
  maintenance_window     = "Mon:04:00-Mon:05:00"

  # Monitoring Configuration
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                  = var.monitoring_role_arn
  enabled_cloudwatch_logs_exports      = ["postgresql", "upgrade"]

  # Update and Delete Protection
  auto_minor_version_upgrade = true
  deletion_protection       = true
  skip_final_snapshot      = false
  final_snapshot_identifier = "${var.environment}-final-snapshot"
  copy_tags_to_snapshot    = true

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Service     = "rails-api"
    Role        = "primary"
  }
}

# Read Replicas
resource "aws_db_instance" "replica" {
  count = var.read_replica_count

  identifier = "${var.environment}-replica-${count.index + 1}"
  
  # Replica Configuration
  replicate_source_db = aws_db_instance.primary.id
  instance_class     = var.replica_instance_class

  # Network Configuration
  vpc_security_group_ids = var.security_group_ids

  # Parameter Groups
  parameter_group_name = aws_db_parameter_group.this.name

  # Backup Configuration (disabled for replicas)
  backup_retention_period = 0
  
  # High Availability Configuration
  multi_az = false

  # Storage Configuration
  storage_encrypted = true

  # Monitoring Configuration
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                  = var.monitoring_role_arn
  enabled_cloudwatch_logs_exports      = ["postgresql", "upgrade"]

  # Update Configuration
  auto_minor_version_upgrade = true

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Service     = "rails-api"
    Role        = "replica"
  }
}

# Outputs
output "primary_endpoint" {
  value       = aws_db_instance.primary.endpoint
  description = "Primary RDS instance endpoint"
}

output "primary_address" {
  value       = aws_db_instance.primary.address
  description = "Primary RDS instance address"
}

output "primary_port" {
  value       = aws_db_instance.primary.port
  description = "Primary RDS instance port"
}

output "primary_id" {
  value       = aws_db_instance.primary.id
  description = "Primary RDS instance ID"
}

output "primary_arn" {
  value       = aws_db_instance.primary.arn
  description = "Primary RDS instance ARN"
}

output "replica_endpoints" {
  value       = aws_db_instance.replica[*].endpoint
  description = "List of read replica endpoints"
}

output "replica_addresses" {
  value       = aws_db_instance.replica[*].address
  description = "List of read replica addresses"
}

output "replica_ports" {
  value       = aws_db_instance.replica[*].port
  description = "List of read replica ports"
}

output "replica_ids" {
  value       = aws_db_instance.replica[*].id
  description = "List of read replica IDs"
}