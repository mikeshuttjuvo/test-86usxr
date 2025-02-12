# Terraform variables for Rails API service infrastructure
# Version: 1.0.0

# Region Configuration
variable "aws_region" {
  description = "AWS region for infrastructure deployment"
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d{1}$", var.aws_region))
    error_message = "AWS region must be a valid region identifier"
  }
}

# Environment Configuration
variable "environment" {
  description = "Deployment environment (staging/production)"
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Environment must be either 'staging' or 'production'"
  }
}

# Project Configuration
variable "project_name" {
  description = "Name of the project for resource tagging"
  type        = string
  default     = "rails-api-service"
}

# Networking Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

# ECS Configuration
variable "ecs_task_cpu" {
  description = "CPU units for ECS tasks (256 = 0.25 vCPU)"
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.ecs_task_cpu)
    error_message = "Task CPU must be one of: 256, 512, 1024, 2048, 4096"
  }
}

variable "ecs_task_memory" {
  description = "Memory (MiB) for ECS tasks"
  type        = number
  default     = 512

  validation {
    condition     = var.ecs_task_memory >= 512 && var.ecs_task_memory <= 30720
    error_message = "Task memory must be between 512 and 30720 MiB"
  }
}

variable "ecs_desired_count" {
  description = "Desired number of ECS tasks"
  type        = number
  default     = 2
}

# Database Configuration
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.large"

  validation {
    condition     = can(regex("^db\\.(t3|r5|r6)\\.", var.db_instance_class))
    error_message = "Instance class must be a valid RDS instance type"
  }
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in GB"
  type        = number
  default     = 100

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 16384
    error_message = "Allocated storage must be between 20 and 16384 GB"
  }
}

# Redis Configuration
variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.t3.medium"
}

variable "redis_num_cache_nodes" {
  description = "Number of cache nodes in the Redis cluster"
  type        = number
  default     = 2

  validation {
    condition     = var.redis_num_cache_nodes > 0 && var.redis_num_cache_nodes <= 6
    error_message = "Number of cache nodes must be between 1 and 6"
  }
}

# Monitoring Configuration
variable "enable_monitoring" {
  description = "Enable enhanced monitoring and logging"
  type        = bool
  default     = true
}

# Backup Configuration
variable "backup_retention_period" {
  description = "Number of days to retain backups"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "Backup retention period must be between 0 and 35 days"
  }
}