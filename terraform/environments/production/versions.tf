terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.42" }
    helm = { source = "hashicorp/helm", version = "~> 3.0" }
  }
}
