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
      sealed-secrets/       # Secrets criptografados (kubeseal)
      secrets.example.yaml  # Modelo das chaves, nao incluido no Kustomize
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
   Argo CD, metrics-server, Traefik e Sealed Secrets.
2. Publique as imagens e gere os SealedSecrets conforme as secoes abaixo.
3. Registre a [Application](argocd/application.yaml) e faca sync manual,
   seguindo o [guia do Argo CD](argocd/README.md).

A conta do lab e `042444213801`, em `us-east-1`. Endpoints e credenciais
devem vir da infraestrutura atual, nao de uma sessao antiga.
O Argo CD acompanha `feature/argocd`; altere a revisao apos o merge.

### Publicar imagens no ECR

Apos o merge em `main`, os workflows de CI publicam a imagem com a tag
`sha-<commit>` e atualizam o overlay automaticamente (ver
[publicacao de tags pelo CI](argocd/README.md#publicacao-de-tags-pelo-ci)).
O processo manual abaixo serve para o primeiro deploy ou para testar a
partir de outra branch.

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
Use apenas tags `sha-...` ou de commit que existem no ECR; o CI nao publica
`latest`.
Faca commit e push desse arquivo. O Argo CD le o Git remoto, nao sua maquina.

### Secrets: SealedSecrets versionados no Git

Os seis Secrets ficam em `overlays/production/sealed-secrets/` como
`SealedSecret`: criptografados com a chave publica do controller instalado
pelo Terraform (`sealed-secrets-controller`, namespace `kube-system`). So o
controller deste cluster consegue descriptografa-los; o Argo CD aplica os
SealedSecrets e o controller cria os Secrets correspondentes.

```text
Secret (local, fora do Git) --kubeseal--> SealedSecret (Git)
  --Argo CD--> SealedSecret (cluster) --controller--> Secret (cluster)
```

O escopo e `strict`: o SealedSecret so abre com o **mesmo nome e namespace**
(`production`) usados ao criptografar. Renomear ou mudar o namespace exige
gerar o arquivo de novo.

Instale o cliente: `brew install kubeseal`.

```bash
export CTX=arn:aws:eks:us-east-1:042444213801:cluster/toggle-master-eks
SEAL="kubeseal --context $CTX --controller-namespace kube-system --controller-name sealed-secrets-controller --format yaml"
```

`secrets.example.yaml` documenta as chaves de cada Secret. Para gerar um
SealedSecret a partir de um Secret preenchido localmente (nunca commitado):

- Use `terraform output` para os endpoints RDS/Valkey, URL SQS e nome DynamoDB.
- Obtenha a senha RDS no Secrets Manager. `POSTGRES_HOST` recebe so o host.
- Em `DATABASE_URL`, aplique percent-encoding na senha.
- Use `rediss://` no Valkey, pois o modulo habilita TLS.

```bash
$SEAL < /caminho/fora/do/repo/postgres-admin-secret.yaml \
  > k8s/overlays/production/sealed-secrets/postgres-admin-secret.yaml
```

Para alterar uma unica chave sem expor as demais, use `--merge-into`.
Exemplo: renovar as credenciais temporarias do AWS Academy, que expiram:

```bash
for s in evaluation-service-secret analytics-service-secret; do
  kubectl create secret generic "$s" -n production --dry-run=client -o json \
    --from-literal=AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)" \
    --from-literal=AWS_SESSION_TOKEN="$(aws configure get aws_session_token)" \
    | $SEAL --merge-into "k8s/overlays/production/sealed-secrets/$s.yaml"
done
git commit -am "chore(secrets): rotate AWS lab credentials" && git push
```

Depois do sync, reinicie evaluation-service e analytics-service para que
carreguem os valores novos:

```bash
kubectl --context "$CTX" -n production rollout restart \
  deployment/evaluation-service deployment/analytics-service
```

Para conferir se o controller abriu os arquivos (condicao `Synced=True`):

```bash
kubectl --context "$CTX" -n production get sealedsecrets
kubectl --context "$CTX" -n production get secrets
```

Cuidados:

- A chave privada existe so no cluster. Se o EKS for recriado, os arquivos
  atuais nao abrem mais: gere-os de novo com o certificado do novo controller.
- Nao edite manualmente o Secret gerado; altere o SealedSecret no Git.
- Aplicar um SealedSecret direto no cluster sem commit funciona so ate o
  proximo sync: o Argo CD volta para a versao do Git.
- Variaveis de ambiente so sao lidas na inicializacao do pod; apos trocar um
  Secret, faca `rollout restart` do Deployment.
- O historico do Git ainda contem os Secrets antigos em base64: rotacione-os.

### Gerar a chave de evaluation-service

Depois do primeiro sync, encaminhe o auth-service em outro terminal:

```bash
kubectl --context "$CTX" -n production port-forward svc/auth-service 8001:8001
```

A `MASTER_KEY` so existe no cluster. Leia-a sem exibir no terminal:

```bash
MASTER_KEY=$(kubectl --context "$CTX" -n production get secret auth-service-secret \
  -o jsonpath='{.data.MASTER_KEY}' | base64 -d)
API_KEY=$(curl --fail -s -X POST http://localhost:8001/admin/keys \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"evaluation-service"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])')
kubectl create secret generic evaluation-service-secret -n production --dry-run=client -o json \
  --from-literal=SERVICE_API_KEY="$API_KEY" \
  | $SEAL --merge-into k8s/overlays/production/sealed-secrets/evaluation-service-secret.yaml
unset MASTER_KEY API_KEY
```

Faca commit e push, sincronize no Argo CD e reinicie evaluation-service:

```bash
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
