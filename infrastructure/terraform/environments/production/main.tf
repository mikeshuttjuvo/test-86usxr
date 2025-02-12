# Production environment Terraform configuration for Rails API infrastructure
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
    bucket         = "rest-api-terraform-state-prod"
    key            = "production/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "terraform-state-lock-prod"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    Environment    = "production"
    Project        = "rest-api-service"
    ManagedBy     = "terraform"
  }
}

# Root infrastructure module with production configuration
module "api_infrastructure" {
  source = "../../main"

  environment         = "production"
  aws_region         = var.aws_region
  vpc_cidr           = var.vpc_cidr
  enable_nat_gateway = true
  enable_multi_az    = true

  # Database configuration for high performance
  db_instance_class        = "db.r6g.xlarge"
  db_allocated_storage     = 100
  db_max_allocated_storage = 500
  read_replica_count       = 2
  
  # Redis configuration for distributed caching
  redis_node_type       = "cache.r6g.large"
  redis_num_cache_nodes = 3
  
  # ECS configuration for application scaling
  ecs_task_cpu       = 1024
  ecs_task_memory    = 2048
  ecs_min_capacity   = 3
  ecs_max_capacity   = 10
  ecs_desired_count  = 3
  
  # Production-grade backup and monitoring
  backup_retention_days       = 30
  enable_performance_insights = true
}

# CloudFront distribution for global content delivery
resource "aws_cloudfront_distribution" "api" {
  enabled             = true
  price_class         = "PriceClass_All"
  http_version        = "http2"
  is_ipv6_enabled     = true
  web_acl_id          = aws_wafv2_web_acl.api.id
  wait_for_deployment = false

  origin {
    domain_name = module.api_infrastructure.alb_dns_name
    origin_id   = "ALB"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 60
      origin_read_timeout      = 60
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "ALB"
    viewer_protocol_policy = "redirect-to-https"
    compress              = true

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Host"]

      cookies {
        forward = "whitelist"
        whitelisted_names = ["session"]
      }
    }
  }

  logging_config {
    include_cookies = true
    bucket         = aws_s3_bucket.logs.bucket_domain_name
    prefix         = "cloudfront/"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.api.arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method       = "sni-only"
  }

  tags = {
    Environment = "production"
    Service     = "api"
  }
}

# Route 53 DNS configuration with health checks
resource "aws_route53_record" "api" {
  zone_id = var.route53_zone_id
  name    = "api.example.com"
  type    = "A"

  alias {
    name                   = module.api_infrastructure.alb_dns_name
    zone_id                = module.api_infrastructure.alb_zone_id
    evaluate_target_health = true
  }

  health_check {
    type                   = "HTTPS"
    port                   = 443
    resource_path         = "/health"
    failure_threshold     = "3"
    request_interval      = "30"
    regions               = ["us-west-1", "us-east-1", "eu-west-1"]
    enable_sni           = true
    search_string        = "\"status\":\"healthy\""
    measure_latency      = true
  }
}

# Outputs for other modules/systems to consume
output "api_endpoint" {
  description = "Production API endpoint URL"
  value       = "https://${aws_route53_record.api.name}"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for API caching"
  value       = aws_cloudfront_distribution.api.id
}

output "alb_dns_name" {
  description = "Application Load Balancer DNS name"
  value       = module.api_infrastructure.alb_dns_name
}

output "rds_endpoint" {
  description = "RDS cluster endpoint"
  value       = module.api_infrastructure.rds_endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "Redis cluster endpoint"
  value       = module.api_infrastructure.redis_endpoint
  sensitive   = true
}