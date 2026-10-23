# Terraform do laboratorio AWS

Execute os comandos a partir da raiz do repositorio. A stack
`environments/production` provisiona a infraestrutura AWS e instala Argo CD,
metrics-server e Traefik pelo provider Helm. A stack `development` contem
somente ECR; ela nao e necessaria para o Minikube.

## Inicializar

Use Terraform >= 1.10 (o backend usa `use_lockfile`), AWS CLI e credenciais
validas. A identidade precisa de acesso a AWS e ao Kubernetes do EKS.
No AWS Academy, atualize o profile quando a sessao expirar.

```bash
export AWS_PROFILE=aws-lab
aws sts get-caller-identity
cd terraform/environments/production
terraform init
terraform fmt -check
terraform validate
```

Para testar a configuracao da plataforma sem AWS, use providers simulados:

```bash
terraform test -filter=tests/platform.tftest.hcl
```

Esse teste faz somente plan em estado isolado; nao valida permissoes reais,
conectividade ao EKS ou a criacao do NLB.

O bucket definido em [backend.tf](environments/production/backend.tf) deve
existir antes do init. Para a conta deste lab, crie-o somente se ainda nao existir:

```bash
aws s3api create-bucket --bucket toggle-master-tfstate-042444213801-prod --region us-east-1
aws s3api put-bucket-versioning --bucket toggle-master-tfstate-042444213801-prod \
  --versioning-configuration Status=Enabled
```

Se alterar o backend de uma stack inicializada, avalie `-reconfigure` versus
`-migrate-state`: nao descarte um state existente.

## Provisionar

Num cluster novo, use duas fases porque o provider Helm depende da API do EKS.
`-target` e uma excecao para bootstrap, nao o fluxo normal:

```bash
terraform plan -target=module.eks -out=eks.tfplan
terraform apply eks.tfplan
terraform plan -out=platform.tfplan
terraform apply platform.tfplan
```

Nos proximos deploys, use plan/apply completo. Revise qualquer substituicao
ou exclusao antes de aplicar. Nada aqui publica imagens ou Secrets.
O EKS e os nodes usam a `LabRole` configurada no tfvars.

O chart Traefik requer Kubernetes >= 1.30. O Service cria um NLB publico
via o controlador legado do EKS; nao requer instalar AWS Load Balancer
Controller. O lab precisa permitir criar balanceadores e suas dependencias.
O Argo CD permanece privado, acessivel por port-forward.

Siga o [guia do Argo CD](../k8s/argocd/README.md) para registrar a unica
Application. Nao instale os mesmos charts por dois gerenciadores.

## Encerrar o laboratorio

EKS, NAT Gateway, NLB, RDS e Valkey geram custos. Antes do destroy, revise o
plano e faca backup dos dados necessarios:

```bash
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

O cluster precisa estar acessivel para o provider Helm remover os releases.
O bucket do state nao pertence a esta stack. Confira a remocao do NLB e
dos demais recursos na AWS antes de encerrar a sessao do lab.
