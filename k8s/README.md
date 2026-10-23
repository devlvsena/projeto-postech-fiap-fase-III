# Kubernetes: desenvolvimento local e laboratorio AWS

Os manifests usam Kustomize para compartilhar os recursos dos microsservicos.

```text
k8s/
  argocd/                   # Uma Application, somente no EKS
    application.yaml
    values.yaml             # Lido pelo Terraform
    README.md
  base/                     # Deployments, Services, HPAs e scripts SQL
  overlays/
    development/            # Minikube: banco, cache e emuladores locais
    production/             # EKS: RDS, Valkey, SQS e DynamoDB externos
      secrets.example.yaml  # Modelo, nao incluido no Kustomize
```

## Desenvolvimento: Minikube sem Argo CD

```bash
minikube start
minikube addons enable ingress
minikube addons enable metrics-server

for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  minikube image build -t "projeto-postech-fiap-fase-ii-$svc:latest" \
    "./toggle-master/microsservices/$svc-main"
done

kubectl --context minikube apply -k k8s/overlays/development
kubectl --context minikube -n development get pods,hpa,ingress
```

Os Secrets de development tem valores ficticios, usados somente no Minikube.
O overlay nao depende do Argo CD. Se ele ainda estiver instalado no seu
cluster local, veja a migracao no [guia do Argo CD](argocd/README.md).
Nao habilite addons enquanto outro controller gerenciar os mesmos recursos.

## AWS: infraestrutura com Terraform, aplicacao com Argo CD

1. [Terraform](../terraform/README.md) cria a infraestrutura e instala
   Argo CD, metrics-server e Traefik.
2. Publique as imagens e prepare os Secrets conforme as secoes abaixo.
3. Registre a [Application](argocd/application.yaml) e faca sync manual,
   seguindo o [guia do Argo CD](argocd/README.md).

A conta do lab e `042444213801`, em `us-east-1`. Endpoints e credenciais
devem vir da infraestrutura atual, nao de uma sessao antiga.
O Argo CD acompanha `feature/argocd`; altere a revisao apos o merge.

### Publicar imagens no ECR

Execute na raiz do repositorio, com Docker disponivel:

```bash
export AWS_PROFILE=aws-lab
export AWS_REGION=us-east-1
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TAG=$(git rev-parse --short HEAD)

(
  set -euo pipefail
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

  for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
    IMAGE="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$svc:$TAG"
    docker build --platform linux/amd64 -t "$IMAGE" "./toggle-master/microsservices/$svc-main"
    docker push "$IMAGE"
  done
)
```

Confira que **todos os cinco pushes** terminaram com sucesso antes de seguir.
O Terraform cria repositorios com nomes simples, como `auth-service`, sem
`togglemaster/`. As tags sao imutaveis: nao sobrescreva uma tag existente.
Os nodes padrao sao x86_64, por isso o build especifica `linux/amd64`.

Com a CLI `kustomize` instalada, atualize o overlay:

```bash
(
  cd k8s/overlays/production
  for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
    kustomize edit set image "$svc=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$svc:$TAG" || exit 1
  done
)
```

Alternativamente, edite os cinco `newName`/`newTag` no
[kustomization.yaml](overlays/production/kustomization.yaml).
O `latest` presente no arquivo e um valor inicial, **nao uma imagem publicada
garantida**. Troque-o por tags reais antes do primeiro sync.
Faca commit e push desse arquivo. O Argo CD le o Git remoto, nao sua maquina.
A pipeline de imagens existente nao substitui automaticamente esse passo.

### Secrets fora do Git

Os seis Secrets nao fazem parte do overlay: sao pre-requisitos aplicados
manualmente no lab. O Argo CD nao altera nem recria seus valores.

```bash
export CTX=arn:aws:eks:us-east-1:042444213801:cluster/toggle-master-eks
kubectl --context "$CTX" apply -f k8s/overlays/production/namespace.yaml
cp k8s/overlays/production/secrets.example.yaml k8s/overlays/production/secrets.local.yaml
chmod 600 k8s/overlays/production/secrets.local.yaml
```

Preencha `secrets.local.yaml`, ignorado pelo Git, antes de aplica-lo:

- Use `terraform output` para os endpoints RDS/Valkey, URL SQS e nome DynamoDB.
  Os outputs ficam na stack `terraform/environments/production`.
- Obtenha a senha RDS no Secrets Manager. O usuario padrao do modulo e `dbadmin`.
  `POSTGRES_HOST` recebe somente o host, sem `:5432`.
- Em `DATABASE_URL`, codifique caracteres especiais de usuario/senha com
  percent-encoding. `POSTGRES_PASSWORD` recebe a senha original, nao codificada.
- Use `rediss://` no Valkey, pois o modulo habilita TLS.
- Gere uma `MASTER_KEY` para o lab; nao use credenciais de outras contas.
- Preencha as credenciais temporarias AWS de evaluation/analytics.
  Quando expirarem, atualize os Secrets e reinicie os dois Deployments.
- `SERVICE_API_KEY` sera preenchida depois que auth-service estiver disponivel.
  Este e o unico placeholder esperado durante o bootstrap da aplicacao.

```bash
kubectl --context "$CTX" apply -f k8s/overlays/production/secrets.local.yaml
```

**Nunca commite valores reais, mesmo temporarios ou em base64.** Os arquivos
antigos foram retirados, mas o historico continua contendo valores anteriores:
rotacione-os. Para producao real, prefira um cofre e workload identity.
Se apagar o namespace, reaplique os Secrets antes do sync.

### Gerar a chave de evaluation-service

Depois do primeiro sync, encaminhe o auth-service em outro terminal:

```bash
kubectl --context "$CTX" -n production port-forward svc/auth-service 8001:8001
```

Use a MASTER_KEY do arquivo local, sem registra-la em comandos compartilhados:

```bash
read -s MASTER_KEY
curl --fail -X POST http://localhost:8001/admin/keys \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"evaluation-service"}'
unset MASTER_KEY
```

Copie a chave retornada para `SERVICE_API_KEY` no arquivo local, reaplique
os Secrets e reinicie o servico:

```bash
kubectl --context "$CTX" apply -f k8s/overlays/production/secrets.local.yaml
kubectl --context "$CTX" -n production rollout restart deployment/evaluation-service
```

### Schema e rotas

O [Job do banco](overlays/production/db-init/job.yaml) e um hook Sync.
Ele executa os scripts compartilhados de
[base/postgres-init](base/postgres-init/configmap.yaml) depois dos ConfigMaps
e antes dos Deployments/HPAs. O SQL pode executar novamente, mas erros
reais nao sao ignorados.

O [Ingress](overlays/production/ingress.yaml) usa a classe `traefik` e a
[Middleware](overlays/production/middleware.yaml) StripPrefix. Por exemplo,
`/auth-service/health` chega ao auth-service como `/health`.
O HTTP publico e exclusivo para teste; configure TLS antes de uso real.

```bash
kubectl --context "$CTX" -n production get pods,hpa,ingress
kubectl --context "$CTX" -n production logs job/postgres-schema-init
```

## Validacao sem aplicar

```bash
kubectl kustomize k8s/overlays/development > /dev/null
kubectl kustomize k8s/overlays/production > /dev/null
```

O render nao valida disponibilidade de imagens, Secrets ou conectividade AWS.
