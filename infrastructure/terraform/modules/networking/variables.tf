# Terraform variable definitions for networking module
# Configures VPC, subnets and network components for REST API service infrastructure
# Version: ~> 1.0

variable "project_name" {
  type        = string
  description = "Name of the project for resource tagging"
  default     = "rest-api-service"
}

variable "environment" {
  type        = string
  description = "Environment name (staging/production)"
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Environment must be either staging or production."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.vpc_cidr))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones for subnet creation"
  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones must be specified for high availability."
  }
}

variable "private_subnet_count" {
  type        = number
  description = "Number of private subnets to create"
  default     = 2
  validation {
    condition     = var.private_subnet_count >= 2
    error_message = "At least 2 private subnets are required for high availability."
  }
}

variable "public_subnet_count" {
  type        = number
  description = "Number of public subnets to create"
  default     = 2
  validation {
    condition     = var.public_subnet_count >= 2
    error_message = "At least 2 public subnets are required for high availability."
  }
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Whether to create NAT Gateways for private subnets"
  default     = true
}