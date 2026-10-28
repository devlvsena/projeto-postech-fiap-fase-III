variable "aws_region" {
  description = "Região AWS"
  type        = string
  default     = "us-east-1"
}

variable "argocd_chart_version" {
  description = "Versão do CHART argo-cd"
  type        = string
  default     = "10.10.5"
}

variable "environment" {
  description = "Ambiente"
  type        = string
}

variable "metrics_server_chart_version" {
  description = "Versao do chart metrics-server"
  type        = string
  default     = "3.14.0"
}

variable "sealed_secrets_chart_version" {
  description = "Versao do chart sealed-secrets (controller dos SealedSecrets)"
  type        = string
  default     = "2.20.0"
}

variable "traefik_chart_version" {
  description = "Versao do chart Traefik (requer Kubernetes >= 1.30)"
  type        = string
  default     = "42.1.3"
}

variable "project_name" {
  description = "Nome do projeto"
  type        = string
}

variable "ecr_repositories" {
  description = "Nomes dos repositórios ECR a serem criados"
  type        = list(string)
}

variable "eks_role_arn" {
  description = "Role IAM existente usada pelo cluster e pelos nós do EKS (null = o módulo cria as roles)"
  type        = string
  default     = null
}
