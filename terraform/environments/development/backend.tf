terraform {
  backend "s3" {
    bucket       = "toggle-master-tfstate-dev"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    access_key = "test"
    secret_key = "test"

    endpoints = {
      s3  = "http://localhost:4566"
      sts = "http://localhost:4566"
      iam = "http://localhost:4566"
    }
    
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true

    use_lockfile = true
    encrypt      = true
  }
}