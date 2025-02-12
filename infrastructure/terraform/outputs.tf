# Terraform AWS Provider version >= 4.0.0
# Terraform version >= 1.0.0

# VPC and Networking Outputs
output "vpc_id" {
  description = "ID of the VPC where all resources are deployed"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs where application components are deployed"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs for load balancers and public-facing components"
  value       = aws_subnet.public[*].id
}

output "security_group_ids" {
  description = "Map of security group IDs for different components"
  value = {
    api   = aws_security_group.api.id
    db    = aws_security_group.db.id
    redis = aws_security_group.redis.id
    alb   = aws_security_group.alb.id
  }
}

# ECS Cluster and Service Outputs
output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster running application containers"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_service_names" {
  description = "Names of ECS services running application components"
  value = {
    api    = aws_ecs_service.api.name
    worker = aws_ecs_service.worker.name
  }
}

output "task_definition_arns" {
  description = "ARNs of active task definitions for each service"
  value = {
    api    = aws_ecs_task_definition.api.arn
    worker = aws_ecs_task_definition.worker.arn
  }
}

# Database Outputs
output "rds_endpoint" {
  description = "Endpoint URL for the primary RDS instance"
  value       = aws_db_instance.primary.endpoint
}

output "rds_replica_endpoints" {
  description = "List of endpoint URLs for RDS read replicas"
  value       = aws_db_instance.replica[*].endpoint
}

output "db_name" {
  description = "Name of the application database"
  value       = aws_db_instance.primary.db_name
}

output "db_port" {
  description = "Port number for database connections"
  value       = aws_db_instance.primary.port
}

output "db_username" {
  description = "Master username for database access"
  value       = aws_db_instance.primary.username
  sensitive   = true
}

# Redis Cache Outputs
output "redis_primary_endpoint" {
  description = "Endpoint URL for the primary Redis node"
  value       = aws_elasticache_cluster.primary.cache_nodes[0].address
}

output "redis_replica_endpoints" {
  description = "List of endpoint URLs for Redis read replicas"
  value       = aws_elasticache_cluster.replica[*].cache_nodes[0].address
}

output "redis_port" {
  description = "Port number for Redis connections"
  value       = aws_elasticache_cluster.primary.cache_nodes[0].port
}

# Load Balancer Outputs
output "alb_dns_name" {
  description = "DNS name of the application load balancer"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Route 53 zone ID of the load balancer"
  value       = aws_lb.main.zone_id
}

output "alb_target_groups" {
  description = "Map of ALB target group ARNs for different services"
  value = {
    api   = aws_lb_target_group.api.arn
    blue  = aws_lb_target_group.blue.arn
    green = aws_lb_target_group.green.arn
  }
}

# Monitoring Outputs
output "cloudwatch_log_groups" {
  description = "Map of CloudWatch log group names for different components"
  value = {
    api    = aws_cloudwatch_log_group.api.name
    worker = aws_cloudwatch_log_group.worker.name
    db     = aws_cloudwatch_log_group.db.name
  }
}

output "metrics_namespace" {
  description = "Namespace for CloudWatch metrics"
  value       = var.app_name
}