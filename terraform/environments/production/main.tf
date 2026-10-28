module "ecr" {
  source = "../../modules/ecr"

  repository_names     = var.ecr_repositories
  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true
  max_image_count      = 10

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

  cluster_role_arn = var.eks_role_arn
  node_role_arn    = var.eks_role_arn
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [
    file("${path.module}/../../../k8s/argocd/values.yaml")
  ]

  wait    = true
  timeout = 600

  depends_on = [module.eks]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version

  wait       = true
  timeout    = 600
  depends_on = [module.eks]
}

# Descriptografa no cluster os SealedSecrets versionados no Git (kubeseal).
resource "helm_release" "sealed_secrets" {
  name       = "sealed-secrets"
  namespace  = "kube-system"
  repository = "https://bitnami.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = var.sealed_secrets_chart_version

  values = [
    yamlencode({
      fullnameOverride = "sealed-secrets-controller"
    })
  ]

  wait       = true
  timeout    = 600
  depends_on = [module.eks]
}

resource "helm_release" "traefik" {
  name             = "traefik"
  namespace        = "traefik"
  create_namespace = true
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version

  values = [
    yamlencode({
      deployment = { replicas = 2 }
      ingressClass = {
        enabled        = true
        isDefaultClass = false
        name           = "traefik"
      }
      providers = {
        kubernetesIngress = {
          ingressClass         = "traefik"
          strictPrefixMatching = true
          publishedService     = { enabled = true }
        }
      }
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"    = "nlb"
          "service.beta.kubernetes.io/aws-load-balancer-subnets" = join(",", module.vpc.public_subnet_ids)
        }
      }
    })
  ]

  wait       = true
  timeout    = 900
  depends_on = [module.eks]
}