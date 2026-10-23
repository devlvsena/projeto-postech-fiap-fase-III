# -- General configuration for the production environment
aws_region   = "us-east-1"
project_name = "toggle-master"
environment  = "production"

## -- ECR configuration
ecr_repositories = [
  "analytics-service",
  "auth-service",
  "evaluation-service",
  "flag-service",
  "targeting-service"
]

## -- Argo CD configuration (versão do CHART argo-cd, não do app)
argocd_chart_version         = "10.10.5"
metrics_server_chart_version = "3.14.0"
traefik_chart_version        = "42.1.3"

## -- EKS configuration (AWS Academy não permite criar roles IAM)
eks_role_arn = "arn:aws:iam::042444213801:role/LabRole"
