variable "name" {
  description = "Nome do cluster EKS (também usado como prefixo nos outros recursos)"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas do EKS (para o cluster e para os nós; use 2+ AZs)"
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes. null = a versão padrão atual do EKS (em produção, fixe uma)"
  type        = string
  default     = null
}

variable "instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "desired_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 3
}
variable "cluster_role_arn" {
  description = "ARN de uma role IAM existente para o plano de controle. null = o módulo cria a role"
  type        = string
  default     = null
}

variable "node_role_arn" {
  description = "ARN de uma role IAM existente para os nós. null = o módulo cria a role"
  type        = string
  default     = null
}
