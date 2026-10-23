mock_provider "aws" {}
mock_provider "helm" {}

override_module {
  target = module.eks
  outputs = {
    cluster_name                       = "toggle-master-eks"
    cluster_endpoint                   = "https://eks.example.test"
    cluster_certificate_authority_data = "dGVzdA=="
  }
}

override_module {
  target = module.vpc
  outputs = {
    vpc_id            = "vpc-00000000000000001"
    vpc_cidr          = "10.0.0.0/16"
    public_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    eks_subnet_ids    = ["subnet-00000000000000003", "subnet-00000000000000004"]
    db_subnet_ids     = ["subnet-00000000000000005", "subnet-00000000000000006"]
  }
}

run "platform_configuration" {
  command = plan

  assert {
    condition     = helm_release.argocd.chart == "argo-cd" && helm_release.argocd.namespace == "argocd"
    error_message = "Argo CD deve ser instalado pelo Terraform no namespace argocd."
  }

  assert {
    condition = (
      yamldecode(helm_release.argocd.values[0]).server.service.type == "ClusterIP" &&
      yamldecode(helm_release.argocd.values[0]).configs.params["server.insecure"] == false
    )
    error_message = "Argo CD deve permanecer privado e com HTTPS."
  }

  assert {
    condition     = helm_release.metrics_server.chart == "metrics-server" && helm_release.metrics_server.namespace == "kube-system"
    error_message = "Metrics-server deve ser instalado no kube-system."
  }

  assert {
    condition = (
      yamldecode(helm_release.traefik.values[0]).deployment.replicas == 2 &&
      yamldecode(helm_release.traefik.values[0]).ingressClass.name == "traefik" &&
      yamldecode(helm_release.traefik.values[0]).providers.kubernetesIngress.strictPrefixMatching == true &&
      yamldecode(helm_release.traefik.values[0]).service.type == "LoadBalancer" &&
      yamldecode(helm_release.traefik.values[0]).service.annotations["service.beta.kubernetes.io/aws-load-balancer-type"] == "nlb" &&
      yamldecode(helm_release.traefik.values[0]).service.annotations["service.beta.kubernetes.io/aws-load-balancer-subnets"] == join(",", module.vpc.public_subnet_ids)
    )
    error_message = "Traefik deve publicar a classe traefik via NLB com rotas Prefix estritas."
  }

  assert {
    condition = (
      helm_release.sealed_secrets.chart == "sealed-secrets" &&
      helm_release.sealed_secrets.namespace == "kube-system" &&
      yamldecode(helm_release.sealed_secrets.values[0]).fullnameOverride == "sealed-secrets-controller"
    )
    error_message = "Sealed Secrets deve rodar em kube-system com o nome padrao esperado pelo kubeseal."
  }
}
