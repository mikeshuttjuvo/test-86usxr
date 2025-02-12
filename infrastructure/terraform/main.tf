# Main Terraform configuration for Rails API service infrastructure
# Version: 1.0.0

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket         = "terraform-state"
    key            = "api-service/terraform.tfstate"
    region         = var.aws_region
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    Environment         = var.environment
    Project            = var.project_name
    ManagedBy          = "terraform"
    BackupSchedule     = "daily"
    SecurityCompliance = "high"
  }
}

locals {
  common_tags = {
    Environment         = var.environment
    Project            = var.project_name
    ManagedBy          = "terraform"
    BackupSchedule     = "daily"
    SecurityCompliance = "high"
  }
}

# Random string for unique resource naming
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Networking Module
module "networking" {
  source = "./modules/networking"

  vpc_cidr            = var.vpc_cidr
  environment         = var.environment
  enable_nat_gateway  = var.enable_nat_gateway
  az_count           = 3
  enable_vpn_gateway  = true
  enable_flow_logs    = true
  flow_logs_retention = 30

  tags = local.common_tags
}

# ECS Module
module "ecs" {
  source = "./modules/ecs"

  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  task_cpu            = var.ecs_task_cpu
  task_memory         = var.ecs_task_memory
  desired_count       = var.ecs_desired_count
  environment         = var.environment

  enable_container_insights    = true
  auto_scaling_min_capacity   = 2
  auto_scaling_max_capacity   = 10
  health_check_grace_period   = 60

  depends_on = [module.networking]
  tags       = local.common_tags
}

# RDS Module
module "rds" {
  source = "./modules/rds"

  vpc_id               = module.networking.vpc_id
  database_subnet_ids  = module.networking.database_subnet_ids
  instance_class       = var.db_instance_class
  allocated_storage    = var.db_allocated_storage
  environment          = var.environment

  multi_az                    = true
  backup_retention_period     = 7
  enable_performance_insights = true
  storage_encrypted          = true
  deletion_protection        = true

  depends_on = [module.networking]
  tags       = local.common_tags
}

# Redis Module
module "redis" {
  source = "./modules/redis"

  vpc_id            = module.networking.vpc_id
  cache_subnet_ids  = module.networking.database_subnet_ids
  node_type         = var.redis_node_type
  num_cache_nodes   = var.redis_num_cache_nodes
  environment       = var.environment

  automatic_failover_enabled   = true
  multi_az_enabled            = true
  at_rest_encryption_enabled  = true
  transit_encryption_enabled  = true

  depends_on = [module.networking]
  tags       = local.common_tags
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "CPUUtilization"
  namespace          = "AWS/ECS"
  period             = "300"
  statistic          = "Average"
  threshold          = "80"
  alarm_description  = "ECS CPU utilization is too high"
  alarm_actions      = []  # Add SNS topic ARN for notifications

  dimensions = {
    ClusterName = module.ecs.cluster_name
    ServiceName = module.ecs.service_name
  }

  tags = local.common_tags
}

# Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.primary_endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "Redis endpoint"
  value       = module.redis.endpoint
  sensitive   = true
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = module.ecs.service_name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group name"
  value       = module.ecs.cloudwatch_log_group
}