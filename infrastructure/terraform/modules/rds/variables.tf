# Core environment variable
variable "environment" {
  type        = string
  description = "Environment name (e.g., staging, production)"
  validation {
    condition     = can(regex("^(staging|production)$", var.environment))
    error_message = "Environment must be either 'staging' or 'production'"
  }
}

# Instance configuration variables
variable "instance_class" {
  type        = string
  description = "RDS instance class for primary instance"
  validation {
    condition     = can(regex("^db\\.(t3|r5|r6g)\\.(large|xlarge|2xlarge)$", var.instance_class))
    error_message = "Instance class must be db.t3.large or higher"
  }
}

variable "engine_version" {
  type        = string
  description = "PostgreSQL engine version"
  default     = "14.7"
  validation {
    condition     = can(regex("^14\\.[0-9]+$", var.engine_version))
    error_message = "Engine version must be PostgreSQL 14.x"
  }
}

# Storage configuration variables
variable "allocated_storage" {
  type        = number
  description = "Initial allocated storage in GB"
  validation {
    condition     = var.allocated_storage >= 100
    error_message = "Allocated storage must be at least 100 GB"
  }
}

variable "max_allocated_storage" {
  type        = number
  description = "Maximum auto-scaling storage limit in GB"
  validation {
    condition     = var.max_allocated_storage > var.allocated_storage
    error_message = "Maximum storage must be greater than initial storage"
  }
}

# Backup configuration
variable "backup_retention_period" {
  type        = number
  description = "Number of days to retain automated backups"
  default     = 7
  validation {
    condition     = var.backup_retention_period >= 7
    error_message = "Backup retention period must be at least 7 days"
  }
}

# Read replica configuration
variable "read_replica_count" {
  type        = number
  description = "Number of read replicas to create"
  default     = 2
  validation {
    condition     = var.read_replica_count >= (var.environment == "production" ? 2 : 1) && var.read_replica_count <= 5
    error_message = "Production requires at least 2 read replicas, maximum 5 replicas allowed"
  }
}

variable "replica_instance_class" {
  type        = string
  description = "RDS instance class for read replicas"
  validation {
    condition     = can(regex("^db\\.(t3|r5|r6g)\\.(large|xlarge|2xlarge)$", var.replica_instance_class))
    error_message = "Replica instance class must be db.t3.large or higher"
  }
}

# High availability configuration
variable "multi_az" {
  type        = bool
  description = "Enable Multi-AZ deployment for high availability"
  default     = true
}

# Network configuration
variable "database_subnet_ids" {
  type        = list(string)
  description = "List of subnet IDs for RDS deployment"
}

variable "security_group_ids" {
  type        = list(string)
  description = "List of security group IDs for RDS instances"
}

# Authentication configuration
variable "master_username" {
  type        = string
  description = "Master username for RDS instance"
  sensitive   = true
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.master_username)) && length(var.master_username) >= 8
    error_message = "Master username must start with a letter, be at least 8 characters, and contain only alphanumeric characters"
  }
}

variable "master_password" {
  type        = string
  description = "Master password for RDS instance"
  sensitive   = true
  validation {
    condition     = length(var.master_password) >= 16 && can(regex("[A-Z]", var.master_password)) && can(regex("[a-z]", var.master_password)) && can(regex("[0-9]", var.master_password)) && can(regex("[!@#$%^&*()]", var.master_password))
    error_message = "Master password must be at least 16 characters and include uppercase, lowercase, numbers, and special characters"
  }
}