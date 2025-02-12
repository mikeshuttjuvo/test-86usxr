# Project and Environment Variables
variable "project_name" {
  type        = string
  description = "Name of the project for resource naming and tagging. Required for consistent resource identification."

  validation {
    condition     = length(var.project_name) > 0
    error_message = "Project name must not be empty."
  }
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., production, staging) for resource tagging and isolation."

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be one of: production, staging, development."
  }
}

# Network Configuration Variables
variable "vpc_id" {
  type        = string
  description = "ID of the VPC where Redis cluster will be deployed. Must be a private VPC with appropriate networking configuration."

  validation {
    condition     = length(var.vpc_id) > 0 && can(regex("^vpc-", var.vpc_id))
    error_message = "VPC ID must be a valid AWS VPC identifier starting with 'vpc-'."
  }
}

variable "private_subnets" {
  type        = list(string)
  description = "List of private subnet IDs for Redis cluster placement. Must be in different AZs for high availability."

  validation {
    condition     = length(var.private_subnets) >= 2
    error_message = "At least two private subnets must be provided for high availability."
  }
}

variable "private_subnets_cidr" {
  type        = list(string)
  description = "List of private subnet CIDR blocks for security group rules. Used to restrict Redis access to specific network segments."

  validation {
    condition     = can([for cidr in var.private_subnets_cidr : regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", cidr)])
    error_message = "Private subnet CIDR blocks must be valid IPv4 CIDR notation."
  }
}

# Redis Configuration Variables
variable "redis_engine_version" {
  type        = string
  default     = "6.x"
  description = "Redis engine version. Defaults to 6.x to meet minimum version requirements for clustering and performance."

  validation {
    condition     = can(regex("^6\\.[0-9x]+$", var.redis_engine_version))
    error_message = "Redis engine version must be 6.x or higher."
  }
}

variable "redis_node_type" {
  type        = string
  description = "Instance type for Redis nodes. Select based on memory and performance requirements (e.g., cache.t3.medium, cache.r5.large)."

  validation {
    condition     = can(regex("^cache\\.[a-z0-9]+\\.[a-z0-9]+$", var.redis_node_type))
    error_message = "Redis node type must be a valid AWS ElastiCache instance type."
  }
}

variable "redis_num_cache_nodes" {
  type        = number
  default     = 2
  description = "Number of cache nodes in the cluster. Minimum 2 recommended for high availability."

  validation {
    condition     = var.redis_num_cache_nodes >= 2
    error_message = "Number of cache nodes must be at least 2 for high availability."
  }
}

# High Availability and Security Variables
variable "enable_multi_az" {
  type        = bool
  default     = true
  description = "Enable Multi-AZ deployment for high availability. Strongly recommended for production environments."
}

variable "enable_encryption" {
  type        = bool
  default     = true
  description = "Enable encryption at rest and in transit. Required for data security compliance."
}

# Maintenance and Backup Variables
variable "maintenance_window" {
  type        = string
  default     = "sun:05:00-sun:09:00"
  description = "Weekly time range for maintenance. Schedule during off-peak hours."

  validation {
    condition     = can(regex("^[a-z]{3}:[0-9]{2}:[0-9]{2}-[a-z]{3}:[0-9]{2}:[0-9]{2}$", var.maintenance_window))
    error_message = "Maintenance window must be in the format 'ddd:hh:mm-ddd:hh:mm'."
  }
}

variable "snapshot_retention_limit" {
  type        = number
  default     = 7
  description = "Number of days to retain Redis backups. Adjust based on recovery requirements."

  validation {
    condition     = var.snapshot_retention_limit >= 0 && var.snapshot_retention_limit <= 35
    error_message = "Snapshot retention limit must be between 0 and 35 days."
  }
}