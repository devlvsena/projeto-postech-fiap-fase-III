provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    sts         = "http://localhost:4566"
    s3          = "http://localhost:4566"
    iam         = "http://localhost:4566"
    ecr         = "http://localhost:4566"
    sqs         = "http://localhost:4566"
    dynamodb    = "http://localhost:4566"
    ec2         = "http://localhost:4566"
    rds         = "http://localhost:4566"
    eks         = "http://localhost:4566"
    elasticache = "http://localhost:4566"
  }

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
