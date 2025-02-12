# Backend configuration for Terraform state management
# Implements secure state storage using AWS S3 with DynamoDB locking
# Version: 1.0.0

terraform {
  backend "s3" {
    # S3 bucket for state storage with environment-specific naming
    bucket = "${var.project_name}-terraform-state-${var.environment}"
    
    # State file path within the bucket
    key = "terraform.tfstate"
    
    # AWS region for state storage
    region = "${var.aws_region}"
    
    # Enable encryption at rest using AWS KMS
    encrypt = true
    
    # Enable server-side encryption
    server_side_encryption_configuration {
      rule {
        apply_server_side_encryption_by_default {
          sse_algorithm = "aws:kms"
        }
      }
    }
    
    # DynamoDB table for state locking
    dynamodb_table = "${var.project_name}-terraform-locks-${var.environment}"
    
    # Use default AWS credentials profile
    profile = "default"
    
    # Enable versioning for state file history
    versioning = true
    
    # Enforce minimum TLS version for secure transport
    min_tls_version = "TLS1_2"
    
    # Configure lifecycle rules for state files
    lifecycle_rule {
      enabled = true
      
      # Transition older versions to cheaper storage
      transition {
        days          = 30
        storage_class = "STANDARD_IA"
      }
      
      # Clean up old versions after 90 days
      noncurrent_version_expiration {
        days = 90
      }
    }
    
    # Enable access logging for audit trails
    logging {
      target_bucket = "${var.project_name}-terraform-logs-${var.environment}"
      target_prefix = "state-access-logs/"
    }
    
    # Enable replication for disaster recovery
    replication_configuration {
      role = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/terraform-state-replication"
      
      rules {
        id     = "state-replication"
        status = "Enabled"
        
        destination {
          bucket        = "${var.project_name}-terraform-state-replica-${var.environment}"
          storage_class = "STANDARD_IA"
          
          # Enable encryption for replicated objects
          encryption_configuration {
            replica_kms_key_id = "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/replica-key-id"
          }
        }
      }
    }
  }
}