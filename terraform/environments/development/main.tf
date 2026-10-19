module "ecr" {
  source = "../../modules/ecr"

  repository_names     = var.ecr_repositories
  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true
  max_image_count      = 5

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "sqs" {
  source = "../../modules/sqs"

  name = "toogle-master-sqs-queue"
}

module "dynamodb" {
  source = "../../modules/data/dynamodb"

  table_name = "ToggleMasterAnalytics"
}

module "vpc" {
  source = "../../modules/network/vpc"

  name = var.project_name
  cidr = "10.0.0.0/16"

  subnets = {
    "public-subnet-app-a"  = { cidr = "10.0.1.0/24", az = "us-east-1a", tier = "public" }
    "public-subnet-app-b"  = { cidr = "10.0.2.0/24", az = "us-east-1b", tier = "public" }
    "private-subnet-eks-a" = { cidr = "10.0.3.0/24", az = "us-east-1a", tier = "eks" }
    "private-subnet-eks-b" = { cidr = "10.0.4.0/24", az = "us-east-1b", tier = "eks" }
    "private-subnet-db-a"  = { cidr = "10.0.5.0/24", az = "us-east-1a", tier = "db" }
    "private-subnet-db-b"  = { cidr = "10.0.6.0/24", az = "us-east-1b", tier = "db" }
  }
}

module "rds" {
  source = "../../modules/data/rds"

  identifier          = "toggle-master-rds"
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.db_subnet_ids
  allowed_cidr_blocks = ["10.0.3.0/24", "10.0.4.0/24"] # subnets do EKS
}

module "elasticache" {
  source = "../../modules/data/elasticache-valkey"

  name                = "toggle-master-cache"
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.db_subnet_ids       # mesmas subnets isoladas do banco
  allowed_cidr_blocks = ["10.0.3.0/24", "10.0.4.0/24"] # subnets do EKS
}

module "eks" {
  source = "../../modules/compute/eks"

  name       = "toggle-master-eks"
  subnet_ids = module.vpc.eks_subnet_ids # private-subnet-eks-a e private-subnet-eks-b
}