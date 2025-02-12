# Primary RDS instance connection details
output "primary_endpoint" {
  description = "Connection endpoint for the primary RDS instance in host:port format"
  value       = aws_db_instance.primary.endpoint
}

output "primary_address" {
  description = "DNS hostname of the primary RDS instance for direct connection"
  value       = aws_db_instance.primary.address
}

output "primary_port" {
  description = "Port number on which the primary RDS instance accepts connections"
  value       = aws_db_instance.primary.port
}

# Read replica connection details
output "replica_endpoints" {
  description = "List of connection endpoints for all read replica instances"
  value       = [for replica in aws_db_instance.replica : replica.endpoint]
}

output "replica_addresses" {
  description = "List of DNS hostnames for all read replica instances"
  value       = [for replica in aws_db_instance.replica : replica.address]
}

# Database configuration
output "database_name" {
  description = "Name of the created PostgreSQL database"
  value       = aws_db_instance.primary.db_name
}

output "master_username" {
  description = "Master username for PostgreSQL database access"
  value       = aws_db_instance.primary.username
  sensitive   = true
}

# Validation rules for endpoint format
locals {
  endpoint_validation = can(regex("^[a-z0-9.-]+$", aws_db_instance.primary.endpoint)) ? null : "Primary endpoint must be a valid DNS name"
  port_validation     = aws_db_instance.primary.port >= 1024 && aws_db_instance.primary.port <= 65535 ? null : "Port must be between 1024 and 65535"
}