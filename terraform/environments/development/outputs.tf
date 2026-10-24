# ---- ECR outputs
output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  value = module.ecr.repository_arns
}

output "ecr_repository_names" {
  value = module.ecr.repository_names
}

# ---- SQS outputs
output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "sqs_queue_arn" {
  value = module.sqs.queue_arn
}

# ---- DynamoDB outputs
output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "dynamodb_table_arn" {
  value = module.dynamodb.table_arn
}

# ---- VPC outputs
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "eks_subnet_ids" {
  value = module.vpc.eks_subnet_ids
}

output "db_subnet_ids" {
  value = module.vpc.db_subnet_ids
}

# ---- RDS outputs
output "rds_endpoint" {
  value = module.rds.endpoint
}

output "rds_arn" {
  value = module.rds.arn
}

output "rds_id" {
  value = module.rds.id
}

# ---- Valkey outputs
output "valkey_endpoint" {
  value = module.elasticache.endpoint
}

output "valkey_port" {
  value = module.elasticache.port
}

# ---- EKS outputs
output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}