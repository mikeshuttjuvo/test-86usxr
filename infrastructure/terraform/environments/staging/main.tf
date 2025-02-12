# Staging Environment Terraform Configuration for Rails API Service
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
    bucket         = "rest-api-terraform-state-staging"
    key            = "staging/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "terraform-state-lock-staging"
  }
}

# Provider Configuration
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "rest-api-service"
      ManagedBy   = "terraform"
    }
  }
}

# Local Variables
locals {
  staging_tags = {
    Environment = var.environment
    Project     = "rest-api-service"
    ManagedBy   = "terraform"
  }
}

# Random ID for unique resource naming
resource "random_id" "staging" {
  byte_length = 4
}

# Networking Module - VPC and Subnet Configuration
module "networking" {
  source = "../../modules/networking"

  vpc_cidr           = var.vpc_cidr
  environment        = var.environment
  enable_nat_gateway = true

  tags = merge(local.staging_tags, {
    Component = "networking"
  })
}

# ECS Module - Container Service Configuration
module "ecs" {
  source = "../../modules/ecs"

  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  task_cpu           = var.ecs_task_cpu
  task_memory        = var.ecs_task_memory
  desired_count      = var.ecs_desired_count
  max_capacity       = var.ecs_max_count
  environment        = var.environment

  depends_on = [module.networking]

  tags = merge(local.staging_tags, {
    Component = "ecs"
  })
}

# RDS Module - Database Configuration
module "rds" {
  source = "../../modules/rds"

  vpc_id               = module.networking.vpc_id
  database_subnet_ids  = module.networking.database_subnet_ids
  instance_class      = var.db_instance_class
  allocated_storage   = var.db_allocated_storage
  environment         = var.environment
  backup_retention_days = var.backup_retention_period
  read_replica_count  = 1  # Reduced for staging

  depends_on = [module.networking]

  tags = merge(local.staging_tags, {
    Component = "database"
  })
}

# Redis Module - Cache Configuration
module "redis" {
  source = "../../modules/redis"

  vpc_id            = module.networking.vpc_id
  cache_subnet_ids  = module.networking.database_subnet_ids
  node_type        = var.redis_node_type
  num_cache_nodes  = var.redis_num_cache_nodes
  environment      = var.environment

  depends_on = [module.networking]

  tags = merge(local.staging_tags, {
    Component = "cache"
  })
}

# CloudWatch Alarms for Monitoring
resource "aws_cloudwatch_metric_alarm" "api_errors" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "staging-api-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "5XXError"
  namespace           = "AWS/ApplicationELB"
  period             = "300"
  statistic          = "Sum"
  threshold          = "10"
  alarm_description  = "This metric monitors API error rate"
  alarm_actions      = []  # Add SNS topic ARN for notifications

  dimensions = {
    LoadBalancer = module.ecs.alb_arn
  }

  tags = merge(local.staging_tags, {
    Component = "monitoring"
  })
}

# Outputs
output "vpc_id" {
  description = "ID of the staging VPC"
  value       = module.networking.vpc_id
}

output "api_endpoint" {
  description = "API endpoint URL"
  value       = module.ecs.api_endpoint
}

output "database_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.database_endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "Redis endpoint"
  value       = module.redis.redis_endpoint
  sensitive   = true
}