# Output definitions for ECS module
# Exposes ECS cluster, service, and IAM role information for use by other modules
# Version: ~> 1.0

output "cluster_id" {
  description = "The ID of the ECS cluster for service and task deployment"
  value       = aws_ecs_cluster.main.id
  type        = string
}

output "cluster_name" {
  description = "The name of the ECS cluster for service discovery and CloudWatch logging"
  value       = aws_ecs_cluster.main.name
  type        = string
}

output "service_id" {
  description = "The ID of the ECS service for task management and updates"
  value       = aws_ecs_service.main.id
  type        = string
}

output "service_name" {
  description = "The name of the ECS service for service discovery and monitoring"
  value       = aws_ecs_service.main.name
  type        = string
}

output "task_execution_role_arn" {
  description = "The ARN of the IAM role used for ECS task execution permissions"
  value       = aws_iam_role.ecs_task_execution_role.arn
  type        = string
}

output "task_role_arn" {
  description = "The ARN of the IAM role used by ECS tasks for AWS service access"
  value       = aws_iam_role.ecs_task_role.arn
  type        = string
}

output "security_group_id" {
  description = "The ID of the security group controlling network access for ECS tasks"
  value       = aws_security_group.ecs_tasks.id
  type        = string
}