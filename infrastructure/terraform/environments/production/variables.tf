# Production environment-specific variables for Rails API infrastructure
# Version: 1.0.0

# Import common variables
variable "environment" {
  description = "Deployment environment identifier"
  type        = string
  default     = "production"

  validation {
    condition     = var.environment == "production"
    error_message = "Environment must be 'production' for this configuration"
  }
}

variable "aws_region" {
  description = "AWS region for production deployment"
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d{1}$", var.aws_region))
    error_message = "AWS region must be a valid region identifier"
  }
}

variable "vpc_cidr" {
  description = "CIDR block for production VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block"
  }
}

variable "ecs_config" {
  description = "ECS cluster and service configuration for high availability and performance"
  type = object({
    task_cpu                           = number
    task_memory                        = number
    min_capacity                       = number
    max_capacity                       = number
    desired_count                      = number
    health_check_grace_period          = number
    cpu_threshold                      = number
    memory_threshold                   = number
    autoscaling_cooldown              = number
    deployment_maximum_percent         = number
    deployment_minimum_healthy_percent = number
  })

  default = {
    task_cpu                           = 1024
    task_memory                        = 2048
    min_capacity                       = 2
    max_capacity                       = 10
    desired_count                      = 2
    health_check_grace_period          = 60
    cpu_threshold                      = 70
    memory_threshold                   = 80
    autoscaling_cooldown              = 300
    deployment_maximum_percent         = 200
    deployment_minimum_healthy_percent = 100
  }

  validation {
    condition     = var.ecs_config.task_cpu >= 512 && var.ecs_config.task_memory >= 1024
    error_message = "ECS task resources must meet minimum production requirements"
  }
}

variable "rds_config" {
  description = "RDS PostgreSQL configuration optimized for production workloads"
  type = object({
    instance_class                    = string
    allocated_storage                 = number
    max_allocated_storage             = number
    read_replica_count                = number
    replica_instance_class            = string
    backup_window                     = string
    maintenance_window                = string
    performance_insights_retention    = number
    deletion_protection               = bool
    auto_minor_version_upgrade        = bool
    monitoring_interval               = number
  })

  default = {
    instance_class                    = "db.r5.large"
    allocated_storage                 = 100
    max_allocated_storage             = 500
    read_replica_count                = 2
    replica_instance_class            = "db.r5.large"
    backup_window                     = "03:00-06:00"
    maintenance_window                = "Mon:04:00-Mon:05:00"
    performance_insights_retention    = 7
    deletion_protection               = true
    auto_minor_version_upgrade        = true
    monitoring_interval               = 60
  }

  validation {
    condition     = can(regex("^db\\.(r5|r6)\\.", var.rds_config.instance_class))
    error_message = "RDS instance class must be production-grade (r5 or r6 family)"
  }
}

variable "redis_config" {
  description = "ElastiCache Redis configuration for high performance caching"
  type = object({
    node_type                    = string
    num_cache_nodes              = number
    engine_version               = string
    maintenance_window           = string
    snapshot_retention_limit     = number
    snapshot_window              = string
    automatic_failover_enabled   = bool
    transit_encryption_enabled   = bool
    at_rest_encryption_enabled   = bool
    multi_az_enabled            = bool
  })

  default = {
    node_type                    = "cache.r5.large"
    num_cache_nodes              = 2
    engine_version               = "6.x"
    maintenance_window           = "sun:05:00-sun:09:00"
    snapshot_retention_limit     = 7
    snapshot_window              = "00:00-03:00"
    automatic_failover_enabled   = true
    transit_encryption_enabled   = true
    at_rest_encryption_enabled   = true
    multi_az_enabled            = true
  }

  validation {
    condition     = can(regex("^cache\\.(r5|r6)\\.", var.redis_config.node_type))
    error_message = "Redis node type must be production-grade (r5 or r6 family)"
  }
}

variable "enable_multi_az" {
  description = "Enable Multi-AZ deployment for high availability"
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Number of days to retain backups"
  type        = number
  default     = 30

  validation {
    condition     = var.backup_retention_period >= 30
    error_message = "Production backup retention period must be at least 30 days"
  }
}

variable "monitoring_config" {
  description = "Comprehensive monitoring and alerting configuration"
  type = object({
    enable_enhanced_monitoring    = bool
    monitoring_interval          = number
    enable_performance_insights  = bool
    log_retention_days          = number
    alarm_cpu_threshold         = number
    alarm_memory_threshold      = number
    alarm_storage_threshold     = number
    alarm_connection_threshold  = number
    enable_cloudwatch_logs      = bool
    enable_audit_logs           = bool
  })

  default = {
    enable_enhanced_monitoring    = true
    monitoring_interval          = 60
    enable_performance_insights  = true
    log_retention_days          = 30
    alarm_cpu_threshold         = 80
    alarm_memory_threshold      = 80
    alarm_storage_threshold     = 85
    alarm_connection_threshold  = 1000
    enable_cloudwatch_logs      = true
    enable_audit_logs           = true
  }

  validation {
    condition     = var.monitoring_config.monitoring_interval <= 60
    error_message = "Production monitoring interval must be 60 seconds or less"
  }
}