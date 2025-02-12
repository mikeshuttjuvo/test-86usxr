# Redis endpoint information
output "redis_endpoint" {
  description = "Primary endpoint address of the Redis cluster for direct connection configuration"
  value       = aws_elasticache_replication_group.redis_cluster.primary_endpoint_address
}

output "redis_port" {
  description = "Port number for Redis cluster connections, used in application configuration"
  value       = aws_elasticache_replication_group.redis_cluster.port
}

# Security group information
output "redis_security_group_id" {
  description = "ID of the security group controlling Redis cluster access for network security configuration"
  value       = aws_security_group.redis_security_group.id
}

# Full connection string for application configuration
output "redis_connection_string" {
  description = "Full Redis connection string for application configuration, including endpoint, port, and database number"
  value       = "redis://${aws_elasticache_replication_group.redis_cluster.primary_endpoint_address}:${aws_elasticache_replication_group.redis_cluster.port}/0"
  sensitive   = true # Marked as sensitive to prevent exposure in logs
}