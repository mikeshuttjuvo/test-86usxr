# Output definitions for networking module
# Exposes VPC and subnet resources for use in other modules
# Version: ~> 1.0

output "vpc_id" {
  description = "The ID of the VPC where all resources will be deployed. Required for resource creation in other modules."
  value       = aws_vpc.main.id
  type        = string
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC for network planning and security group configurations."
  value       = aws_vpc.main.cidr_block
  type        = string
}

output "private_subnet_ids" {
  description = "List of IDs of private subnets across multiple AZs for deploying protected resources like ECS tasks and RDS instances."
  value       = aws_subnet.private[*].id
  type        = list(string)
}

output "public_subnet_ids" {
  description = "List of IDs of public subnets across multiple AZs for deploying internet-facing resources like load balancers."
  value       = aws_subnet.public[*].id
  type        = list(string)
}

output "private_subnet_cidrs" {
  description = "List of CIDR blocks of private subnets for security group rule configurations and network planning."
  value       = aws_subnet.private[*].cidr_block
  type        = list(string)
}

output "public_subnet_cidrs" {
  description = "List of CIDR blocks of public subnets for security group rule configurations and network planning."
  value       = aws_subnet.public[*].cidr_block
  type        = list(string)
}