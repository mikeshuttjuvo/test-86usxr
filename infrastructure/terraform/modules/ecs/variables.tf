# Terraform variable definitions for ECS module
# Configures ECS Fargate cluster, services, tasks and auto-scaling for Rails API application
# Version: ~> 1.0

variable "cluster_name" {
  type        = string
  description = "Name of the ECS cluster"
  validation {
    condition     = length(var.cluster_name) > 0 && can(regex("^[a-zA-Z0-9-]+$", var.cluster_name))
    error_message = "Cluster name must be non-empty and contain only alphanumeric characters and hyphens"
  }
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., production, staging)"
  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be production, staging, or development"
  }
}

variable "task_cpu" {
  type        = number
  description = "CPU units for ECS tasks (1 vCPU = 1024)"
  default     = 1024
  validation {
    condition     = var.task_cpu >= 256 && var.task_cpu <= 4096
    error_message = "Task CPU must be between 256 and 4096 units"
  }
}

variable "task_memory" {
  type        = number
  description = "Memory (in MiB) for ECS tasks"
  default     = 2048
  validation {
    condition     = var.task_memory >= 512 && var.task_memory <= 30720
    error_message = "Task memory must be between 512 and 30720 MiB"
  }
}

variable "desired_count" {
  type        = number
  description = "Desired number of ECS tasks to run"
  default     = 2
  validation {
    condition     = var.desired_count >= 2
    error_message = "Desired count must be at least 2 for high availability"
  }
}

variable "min_capacity" {
  type        = number
  description = "Minimum number of tasks for auto-scaling"
  default     = 2
  validation {
    condition     = var.min_capacity >= 2
    error_message = "Minimum capacity must be at least 2 for high availability"
  }
}

variable "max_capacity" {
  type        = number
  description = "Maximum number of tasks for auto-scaling"
  default     = 10
  validation {
    condition     = var.max_capacity <= 10 && var.max_capacity >= var.min_capacity
    error_message = "Maximum capacity must be less than or equal to 10 and greater than or equal to minimum capacity"
  }
}

variable "health_check_grace_period" {
  type        = number
  description = "Grace period in seconds for health checks"
  default     = 60
  validation {
    condition     = var.health_check_grace_period >= 30 && var.health_check_grace_period <= 300
    error_message = "Health check grace period must be between 30 and 300 seconds"
  }
}

variable "enable_execute_command" {
  type        = bool
  description = "Enable ECS Exec for tasks"
  default     = false
}

variable "container_port" {
  type        = number
  description = "Port exposed by the container"
  default     = 3000
  validation {
    condition     = var.container_port > 0 && var.container_port < 65536
    error_message = "Container port must be between 1 and 65535"
  }
}

variable "container_image" {
  type        = string
  description = "Docker image for the Rails API application"
  validation {
    condition     = can(regex("^\\d+\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9-]+:[a-zA-Z0-9._-]+$", var.container_image))
    error_message = "Container image must be a valid ECR image URI"
  }
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC where ECS resources will be deployed"
  validation {
    condition     = can(regex("^vpc-[a-z0-9]+$", var.vpc_id))
    error_message = "VPC ID must be a valid AWS VPC identifier"
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs for ECS tasks"
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least two private subnets are required for high availability"
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources"
  default     = {}
  validation {
    condition     = can(lookup(var.tags, "Environment", null)) && can(lookup(var.tags, "ManagedBy", null))
    error_message = "Tags must include Environment and ManagedBy keys"
  }
}