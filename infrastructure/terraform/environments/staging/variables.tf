# Staging Environment Variables for Rails API Service
# Inherits and overrides variables from root variables.tf

# Environment Identifier
variable "environment" {
  description = "Deployment environment identifier"
  type        = string
  default     = "staging"

  validation {
    condition     = var.environment == "staging"
    error_message = "Environment must be 'staging' for this configuration"
  }
}

# Region Configuration
variable "aws_region" {
  description = "AWS region for staging deployment"
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d{1}$", var.aws_region))
    error_message = "AWS region must be a valid region identifier"
  }
}

# Network Configuration
variable "vpc_cidr" {
  description = "CIDR block for staging VPC"
  type        = string
  default     = "10.1.0.0/16"
}

# ECS Configuration - Scaled down for staging
variable "ecs_task_cpu" {
  description = "CPU units for ECS tasks in staging"
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024], var.ecs_task_cpu)
    error_message = "Staging task CPU must be one of: 256, 512, 1024"
  }
}

variable "ecs_task_memory" {
  description = "Memory (MiB) for ECS tasks in staging"
  type        = number
  default     = 512

  validation {
    condition     = var.ecs_task_memory >= 512 && var.ecs_task_memory <= 4096
    error_message = "Staging task memory must be between 512 and 4096 MiB"
  }
}

variable "ecs_desired_count" {
  description = "Desired number of ECS tasks in staging"
  type        = number
  default     = 2
}

variable "ecs_max_count" {
  description = "Maximum number of ECS tasks in staging"
  type        = number
  default     = 4
}

# Database Configuration - Cost-optimized for staging
variable "db_instance_class" {
  description = "RDS instance class for staging"
  type        = string
  default     = "db.t3.medium"

  validation {
    condition     = can(regex("^db\\.t3\\.", var.db_instance_class))
    error_message = "Staging must use t3 class instances"
  }
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in staging (GB)"
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 100
    error_message = "Staging storage must be between 20 and 100 GB"
  }
}

# Redis Configuration - Minimal for staging
variable "redis_node_type" {
  description = "ElastiCache Redis node type for staging"
  type        = string
  default     = "cache.t3.small"
}

variable "redis_num_cache_nodes" {
  description = "Number of cache nodes in staging Redis cluster"
  type        = number
  default     = 1
}

# Monitoring Configuration
variable "enable_monitoring" {
  description = "Enable enhanced monitoring in staging"
  type        = bool
  default     = true
}

# Backup Configuration - Reduced retention for staging
variable "backup_retention_period" {
  description = "Number of days to retain backups in staging"
  type        = number
  default     = 3

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 7
    error_message = "Staging backup retention must be between 0 and 7 days"
  }
}

# Resource Tagging
variable "tags" {
  description = "Additional tags for staging resources"
  type        = map(string)
  default = {
    Environment = "staging"
    ManagedBy   = "terraform"
    Project     = "rails-api-service"
  }
}