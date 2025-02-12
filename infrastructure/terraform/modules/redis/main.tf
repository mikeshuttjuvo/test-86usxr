# Provider version constraint
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Redis subnet group for cluster placement
resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name        = "${var.project_name}-${var.environment}-redis-subnet"
  subnet_ids  = var.private_subnets
  description = "Subnet group for Redis cluster in private subnets"

  tags = {
    Name        = "${var.project_name}-${var.environment}-redis-subnet"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

# Redis parameter group for performance optimization
resource "aws_elasticache_parameter_group" "redis_params" {
  family      = "redis6.x"
  name        = "${var.project_name}-${var.environment}-redis-params"
  description = "Custom parameters for Redis cluster optimization"

  # Performance and memory management parameters
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"  # Least Recently Used eviction policy
  }

  parameter {
    name  = "maxmemory-samples"
    value = "10"  # Number of samples for LRU estimation
  }

  # Connection management parameters
  parameter {
    name  = "timeout"
    value = "300"  # Client timeout in seconds
  }

  parameter {
    name  = "tcp-keepalive"
    value = "300"  # TCP keepalive interval
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-redis-params"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

# Security group for Redis cluster access control
resource "aws_security_group" "redis_security_group" {
  name        = "${var.project_name}-${var.environment}-redis-sg"
  description = "Security group for Redis cluster access control"
  vpc_id      = var.vpc_id

  # Inbound rule for Redis access from private subnets
  ingress {
    description = "Redis access from private subnets"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = var.private_subnets_cidr
  }

  # Outbound rule allowing all traffic
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-redis-sg"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

# Redis replication group (cluster) configuration
resource "aws_elasticache_replication_group" "redis_cluster" {
  replication_group_id = "${var.project_name}-${var.environment}-redis"
  description         = "High-availability Redis cluster for REST API caching"

  # Engine configuration
  engine         = "redis"
  engine_version = var.redis_engine_version
  port           = 6379
  node_type      = var.redis_node_type

  # Cluster configuration
  num_cache_clusters         = var.redis_num_cache_nodes
  automatic_failover_enabled = true
  multi_az_enabled          = var.enable_multi_az
  subnet_group_name         = aws_elasticache_subnet_group.redis_subnet_group.name
  security_group_ids        = [aws_security_group.redis_security_group.id]
  parameter_group_name      = aws_elasticache_parameter_group.redis_params.name

  # Security configuration
  at_rest_encryption_enabled = var.enable_encryption
  transit_encryption_enabled = var.enable_encryption
  auth_token                = var.redis_auth_token

  # Maintenance and backup configuration
  maintenance_window      = var.maintenance_window
  snapshot_window        = "00:00-03:00"
  snapshot_retention_limit = var.snapshot_retention_limit
  apply_immediately       = false
  auto_minor_version_upgrade = true

  # Notification configuration
  notification_topic_arn = var.sns_topic_arn

  tags = {
    Name        = "${var.project_name}-${var.environment}-redis"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }

  lifecycle {
    prevent_destroy = true  # Prevent accidental deletion of the Redis cluster
  }
}

# CloudWatch alarms for Redis monitoring
resource "aws_cloudwatch_metric_alarm" "redis_cpu_utilization" {
  alarm_name          = "${var.project_name}-${var.environment}-redis-cpu-utilization"
  alarm_description   = "Redis cluster CPU utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "CPUUtilization"
  namespace          = "AWS/ElastiCache"
  period             = "300"
  statistic          = "Average"
  threshold          = "75"
  alarm_actions      = [var.sns_topic_arn]
  ok_actions         = [var.sns_topic_arn]

  dimensions = {
    CacheClusterId = aws_elasticache_replication_group.redis_cluster.id
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_memory_usage" {
  alarm_name          = "${var.project_name}-${var.environment}-redis-memory-usage"
  alarm_description   = "Redis cluster memory usage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "DatabaseMemoryUsagePercentage"
  namespace          = "AWS/ElastiCache"
  period             = "300"
  statistic          = "Average"
  threshold          = "80"
  alarm_actions      = [var.sns_topic_arn]
  ok_actions         = [var.sns_topic_arn]

  dimensions = {
    CacheClusterId = aws_elasticache_replication_group.redis_cluster.id
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}