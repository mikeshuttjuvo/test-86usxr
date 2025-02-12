# Environment Identifier
environment = "staging"

# AWS Region Configuration
aws_region = "us-west-2"

# Project Information
project_name = "rails-api-service"

# VPC Configuration
vpc_cidr = "10.1.0.0/16"
enable_nat_gateway = true

# ECS Task Configuration - Scaled down for staging
ecs_task_cpu = 256        # 0.25 vCPU
ecs_task_memory = 512     # 512 MiB
ecs_desired_count = 2     # Minimum tasks for HA
ecs_max_count = 4         # Maximum scaling limit

# RDS Configuration - Smaller instance for staging
db_instance_class = "db.t3.medium"
db_allocated_storage = 20  # GB

# Redis Configuration - Minimal setup for staging
redis_node_type = "cache.t3.small"
redis_num_cache_nodes = 1  # Single node for staging

# Monitoring and Backup Configuration
enable_monitoring = true
backup_retention_period = 3  # 3 days retention for staging

# Resource Tags
tags = {
  Environment = "staging"
  ManagedBy   = "terraform"
  Project     = "rails-api-service"
}