# Production Environment Configuration
environment = "production"
aws_region  = "us-west-2"
project_name = "rails-api-service"

# VPC Configuration
vpc_cidr = "10.0.0.0/16"
enable_nat_gateway = true

# ECS Configuration
ecs_config = {
  task_cpu                           = 1024
  task_memory                        = 2048
  min_capacity                       = 2
  max_capacity                       = 10
  desired_count                      = 2
  health_check_grace_period         = 60
  scaling_cpu_threshold             = 70
  scaling_memory_threshold          = 80
  container_insights                = true
  enable_execute_command           = false
  deployment_circuit_breaker       = true
  deployment_maximum_percent       = 200
  deployment_minimum_healthy_percent = 100
}

# RDS Configuration
rds_config = {
  instance_class               = "db.r5.large"
  allocated_storage           = 100
  max_allocated_storage       = 500
  read_replica_count          = 2
  replica_instance_class      = "db.r5.large"
  backup_retention_period     = 30
  multi_az                    = true
  storage_encrypted           = true
  deletion_protection         = true
  performance_insights_enabled = true
  monitoring_interval         = 60
  auto_minor_version_upgrade  = true
  maintenance_window         = "Mon:03:00-Mon:04:00"
  backup_window              = "02:00-03:00"
  skip_final_snapshot        = false
  copy_tags_to_snapshot      = true
}

# Redis Configuration
redis_config = {
  node_type                    = "cache.r5.large"
  num_cache_nodes              = 2
  engine_version               = "6.x"
  maintenance_window           = "sun:05:00-sun:09:00"
  snapshot_retention_limit     = 7
  automatic_failover_enabled   = true
  multi_az_enabled            = true
  transit_encryption_enabled   = true
  at_rest_encryption_enabled   = true
  snapshot_window             = "04:00-05:00"
  parameter_group_family      = "redis6.x"
  port                        = 6379
}

# Monitoring Configuration
monitoring_config = {
  enable_enhanced_monitoring  = true
  monitoring_interval        = 60
  enable_performance_insights = true
  log_retention_days         = 30
  alarm_cpu_threshold        = 70
  alarm_memory_threshold     = 80
  alarm_storage_threshold    = 85
  enable_cloudwatch_logs     = true
  enable_cloudwatch_metrics  = true
  metrics_granularity        = "1Minute"
  log_types                  = ["audit", "error", "general", "slowquery"]
}

# High Availability Configuration
enable_multi_az = true
backup_retention_period = 30

# Security Configuration
security_config = {
  enable_waf               = true
  enable_shield            = true
  enable_guard_duty        = true
  enable_config            = true
  enable_cloud_trail       = true
  ssl_policy              = "ELBSecurityPolicy-TLS-1-2-2017-01"
  enable_secrets_manager   = true
  enable_kms              = true
  enable_network_firewall = true
}