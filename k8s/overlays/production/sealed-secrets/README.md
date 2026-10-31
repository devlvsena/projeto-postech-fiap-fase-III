# Como atualizar os SealedSecrets de produção

Guia passo a passo para qualquer pessoa do time alterar as credenciais usadas
pelos microsserviços em produção (EKS) sem expor valores em texto puro no Git.

- [1. Conceitos](#1-conceitos)
- [2. Inventário dos secrets](#2-inventário-dos-secrets)
- [3. Pré-requisitos](#3-pré-requisitos)
- [4. Preparar o terminal](#4-preparar-o-terminal)
- [5. Atualizar chaves (receitas)](#5-atualizar-chaves-receitas)
- [6. Gerar um arquivo do zero](#6-gerar-um-arquivo-do-zero)
- [7. Validar, commitar e aplicar](#7-validar-commitar-e-aplicar)
- [8. Reiniciar os pods](#8-reiniciar-os-pods)
- [9. Problemas comuns](#9-problemas-comuns)

## 1. Conceitos

```text
Secret local (texto puro, nunca vai ao Git)
   --kubeseal--> SealedSecret (arquivo deste diretório, vai ao Git)
   --Argo CD--> SealedSecret no cluster
   --controller sealed-secrets--> Secret no cluster (lido pelos pods)
```

- Só o controller `sealed-secrets-controller` (namespace `kube-system`) consegue
  descriptografar os arquivos. O `kubeseal` usa apenas a chave **pública** dele.
- O escopo é `strict`: o SealedSecret só abre com o **mesmo nome e namespace**
  (`production`) usados ao criptografar. Não renomeie arquivos nem mude o
  namespace sem gerar o arquivo de novo.
- Se o EKS for recriado, o controller ganha um novo par de chaves e **todos** os
  arquivos daqui precisam ser gerados de novo (seção 6).
- Nunca edite o `Secret` gerado no cluster nem aplique um SealedSecret direto
  com `kubectl apply`: o Argo CD volta para a versão do Git no próximo sync.
- Nunca versione valores em texto puro nem a chave privada do controller.

## 2. Inventário dos secrets

| Arquivo | Chaves |
|---|---|
| [auth-service-secret.yaml](auth-service-secret.yaml) | `DATABASE_URL`, `MASTER_KEY` |
| [flag-service-secret.yaml](flag-service-secret.yaml) | `DATABASE_URL` |
| [targeting-service-secret.yaml](targeting-service-secret.yaml) | `DATABASE_URL` |
| [evaluation-service-secret.yaml](evaluation-service-secret.yaml) | `REDIS_URL`, `AWS_REGION`, `AWS_SQS_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `SERVICE_API_KEY` |
| [analytics-service-secret.yaml](analytics-service-secret.yaml) | `AWS_REGION`, `AWS_SQS_URL`, `AWS_DYNAMODB_TABLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` |
| [postgres-admin-secret.yaml](postgres-admin-secret.yaml) | `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |

O modelo com todas as chaves em texto está em
[../secrets.example.yaml](../secrets.example.yaml) (apenas valores de exemplo).

## 3. Pré-requisitos

- AWS CLI com credenciais válidas (profile do laboratório, ex.: `aws-lab`).
- `kubectl` e `kubeseal` (`brew install kubeseal`).
- `terraform` com `terraform init` feito em `terraform/environments/production`
  (só para consultar outputs).
- Acesso ao cluster `toggle-master-eks`.
- Permissão de push no repositório (ou abra um PR com a alteração).

## 4. Preparar o terminal

Execute na raiz do repositório:

```bash
export AWS_PROFILE=aws-lab    # use o profile que você configurou
export CTX=arn:aws:eks:us-east-1:042444213801:cluster/toggle-master-eks

aws eks update-kubeconfig --name toggle-master-eks --region us-east-1
kubectl --context "$CTX" -n kube-system get pods | grep sealed-secrets

SEAL="kubeseal --context $CTX --controller-namespace kube-system --controller-name sealed-secrets-controller --format yaml"
```

> O profile `aws-lab` é o usado em [k8s/argocd/README.md](../../../argocd/README.md).
> Se o seu for diferente, ajuste `AWS_PROFILE`.

**Cuidado com o histórico do shell.** Para valores sensíveis, leia a entrada sem
eco em vez de digitá-la no comando:

```bash
read -rs -p "Senha do RDS: " DB_PASS; echo
```

### Como funciona cada receita

Todas seguem o mesmo padrão: o `kubectl create secret ... --dry-run=client -o json`
só **gera o JSON** do Secret (nada é criado no cluster) e o `kubeseal`
criptografa e **mescla** apenas as chaves informadas no arquivo existente com
`--merge-into`. As outras chaves do arquivo continuam intactas. O `kubeseal`
pode reordenar as chaves do YAML; isso é normal.

## 5. Atualizar chaves (receitas)

Escolha a receita conforme o que mudou.

### 5.1. Credenciais AWS (AWS Academy expirou)

Afeta `evaluation-service-secret` e `analytics-service-secret`. Primeiro renove
a sessão do laboratório e confirme que ela funciona:

```bash
aws sts get-caller-identity
```

```bash
for s in evaluation-service-secret analytics-service-secret; do
  kubectl create secret generic "$s" -n production --dry-run=client -o json \
    --from-literal=AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)" \
    --from-literal=AWS_SESSION_TOKEN="$(aws configure get aws_session_token)" \
  | $SEAL --merge-into "k8s/overlays/production/sealed-secrets/$s.yaml"
done
```

Depois: [validar e commitar](#7-validar-commitar-e-aplicar) e
[reiniciar](#8-reiniciar-os-pods) `evaluation-service` e `analytics-service`.

### 5.2. Banco de dados (RDS)

A senha do RDS é **gerenciada pela AWS** (Secrets Manager). Recriar o
SealedSecret não rotaciona essa senha; ele apenas reflete a senha vigente.

**Obter host e senha:**

```bash
# Host (sem porta)
aws rds describe-db-instances --db-instance-identifier toggle-master-rds \
  --query 'DBInstances[0].Endpoint.Address' --output text

# ARN do secret com a senha
aws rds describe-db-instances --db-instance-identifier toggle-master-rds \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text

# Usuário e senha (JSON com "username" e "password")
aws secretsmanager get-secret-value --secret-id <ARN> \
  --query SecretString --output text
```

**5.2.1. `DATABASE_URL` de auth, flag e targeting**

A senha precisa de *percent-encoding* dentro da URL (caracteres como `@`, `/`,
`:` e `#` quebram a URL se não forem codificados).

```bash
HOST=<host-do-rds>
read -rs -p "Senha do RDS: " DB_PASS; echo
ENC=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DB_PASS")

for pair in auth-service:auth_db flag-service:flags_db targeting-service:targeting_db; do
  svc=${pair%%:*}; db=${pair##*:}
  kubectl create secret generic "$svc-secret" -n production --dry-run=client -o json \
    --from-literal=DATABASE_URL="postgres://dbadmin:$ENC@$HOST:5432/$db?sslmode=require" \
  | $SEAL --merge-into "k8s/overlays/production/sealed-secrets/$svc-secret.yaml"
done
```

> Troque `dbadmin` pelo `username` retornado pelo Secrets Manager, se for outro.
> O formato `postgres://...` deve seguir o que já funciona hoje; na dúvida,
> confira o `DATABASE_URL` do Secret atual no cluster (seção 9).

**5.2.2. `postgres-admin-secret`**

Aqui a senha vai **sem encoding** e o host **sem porta**. Esse secret é usado
pelo Job `postgres-schema-init`.

```bash
kubectl create secret generic postgres-admin-secret -n production --dry-run=client -o json \
  --from-literal=POSTGRES_HOST="$HOST" \
  --from-literal=POSTGRES_USER=dbadmin \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS" \
| $SEAL --merge-into k8s/overlays/production/sealed-secrets/postgres-admin-secret.yaml
```

Depois, reinicie `auth-service`, `flag-service` e `targeting-service`.

### 5.3. Endpoints (Valkey, SQS, DynamoDB)

Consulte os valores no Terraform:

```bash
cd terraform/environments/production
terraform output -raw valkey_endpoint
terraform output -raw valkey_port
terraform output -raw sqs_queue_url
terraform output -raw dynamodb_table_name
cd -
```

```bash
kubectl create secret generic evaluation-service-secret -n production --dry-run=client -o json \
  --from-literal=REDIS_URL="rediss://<valkey_endpoint>:<valkey_port>" \
  --from-literal=AWS_SQS_URL="<sqs_queue_url>" \
| $SEAL --merge-into k8s/overlays/production/sealed-secrets/evaluation-service-secret.yaml

kubectl create secret generic analytics-service-secret -n production --dry-run=client -o json \
  --from-literal=AWS_SQS_URL="<sqs_queue_url>" \
  --from-literal=AWS_DYNAMODB_TABLE="<dynamodb_table_name>" \
| $SEAL --merge-into k8s/overlays/production/sealed-secrets/analytics-service-secret.yaml
```

Use `rediss://` (dois "s"): o Valkey está com TLS habilitado.

### 5.4. `SERVICE_API_KEY` do evaluation-service

Essa chave é gerada pelo auth-service (`POST /admin/keys`, veja o
[README do auth-service](../../../../toggle-master/microsservices/auth-service-main/README.md)).
Antes dela existir, o arquivo guarda o marcador `REPLACE_AFTER_AUTH_DEPLOY`,
que permite criar o Secret mas **não autentica** o evaluation-service.

Salve **somente** a chave retornada em um arquivo fora do Git, **sem quebra de
linha final**:

```bash
printf '%s' "<chave-retornada>" > /caminho/seguro/service-api-key

kubectl create secret generic evaluation-service-secret -n production --dry-run=client -o json \
  --from-file=SERVICE_API_KEY=/caminho/seguro/service-api-key \
| $SEAL --merge-into k8s/overlays/production/sealed-secrets/evaluation-service-secret.yaml

rm /caminho/seguro/service-api-key
```

### 5.5. `MASTER_KEY` do auth-service

Deve ser um valor aleatório. Gere e sele sem exibir na tela:

```bash
MASTER_KEY=$(openssl rand -hex 32)

kubectl create secret generic auth-service-secret -n production --dry-run=client -o json \
  --from-literal=MASTER_KEY="$MASTER_KEY" \
| $SEAL --merge-into k8s/overlays/production/sealed-secrets/auth-service-secret.yaml

unset MASTER_KEY
```

> A `MASTER_KEY` é usada para chamar `POST /admin/keys`. Trocá-la exige usar a
> nova chave nessas chamadas; verifique o impacto no auth-service antes de
> rotacionar em um ambiente em uso.

## 6. Gerar um arquivo do zero

Use quando criar um secret novo ou depois de recriar o EKS (o controller novo
não abre os arquivos antigos). Preencha **todas** as chaves do secret.

1. Copie o bloco do secret desejado de
   [../secrets.example.yaml](../secrets.example.yaml) para um arquivo **fora do
   repositório** (ex.: `~/secrets/auth-service-secret.yaml`) e preencha os
   valores reais.
2. Sele o arquivo substituindo o existente:

```bash
$SEAL < ~/secrets/auth-service-secret.yaml \
  > k8s/overlays/production/sealed-secrets/auth-service-secret.yaml
```

3. Apague o arquivo em texto puro:

```bash
rm ~/secrets/auth-service-secret.yaml
```

O `metadata.name` e o `namespace: production` do arquivo de origem precisam ser
exatamente os do SealedSecret (escopo `strict`).

Se o secret for **novo**, inclua o arquivo em `resources:` de
[../kustomization.yaml](../kustomization.yaml).

## 7. Validar, commitar e aplicar

Valide todos os arquivos contra o controller (sem aplicar nada):

```bash
for f in k8s/overlays/production/sealed-secrets/*.yaml; do
  $SEAL --validate < "$f" || { echo "FALHOU: $f"; break; }
done
```

Confira o diff. Ele deve mostrar apenas valores criptografados
(`AgB...`/`AgC...`), nunca texto puro:

```bash
git diff --stat k8s/overlays/production/sealed-secrets
git add k8s/overlays/production/sealed-secrets
git commit -m "chore(secrets): update sealed secrets"
git push
```

O Argo CD acompanha o Git (`togglemaster-production`). Para antecipar:

```bash
argocd app sync togglemaster-production
```

Ou use **Refresh** / **Sync** na UI. Confirme que o controller abriu os arquivos
(`Synced=True`) e que os Secrets existem:

```bash
kubectl --context "$CTX" -n production get sealedsecrets
kubectl --context "$CTX" -n production get secrets
```

## 8. Reiniciar os pods

Variáveis vindas de Secret **não mudam** nos pods já em execução. Depois do
sync, reinicie os deployments afetados:

| O que mudou | Reiniciar |
|---|---|
| Credenciais AWS (5.1) | `evaluation-service`, `analytics-service` |
| Banco (5.2) | `auth-service`, `flag-service`, `targeting-service` |
| Endpoints (5.3) | `evaluation-service`, `analytics-service` |
| `SERVICE_API_KEY` (5.4) | `evaluation-service` |
| `MASTER_KEY` (5.5) | `auth-service` |

```bash
kubectl --context "$CTX" -n production rollout restart deployment/evaluation-service deployment/analytics-service
kubectl --context "$CTX" -n production rollout status deployment/evaluation-service
kubectl --context "$CTX" -n production rollout status deployment/analytics-service
```

## 9. Problemas comuns

| Sintoma | Causa e solução |
|---|---|
| `no key could decrypt secret` / SealedSecret sem `Synced=True` | O arquivo foi criptografado com o certificado de outro cluster, ou nome/namespace não conferem. Gere o arquivo de novo com o `$SEAL` deste cluster (seção 6). |
| `kubeseal` não conecta ao controller | Confira `CTX`, o `update-kubeconfig` e se o pod `sealed-secrets` está `Running` em `kube-system`. |
| `ExpiredToken` / `InvalidClientTokenId` nos pods | Credenciais AWS do laboratório expiraram: refaça a seção 5.1 e reinicie os pods. |
| Falha de conexão com o banco após trocar a senha | Senha sem *percent-encoding* na `DATABASE_URL`, ou host com porta em `POSTGRES_HOST`. Refaça a seção 5.2. |
| Pod continua com o valor antigo | Faltou o `rollout restart` (seção 8) ou o Argo CD ainda não sincronizou. |
| Argo CD desfaz minha alteração | Você aplicou direto no cluster. Altere o arquivo no Git e faça push. |
| Quero ver o valor atual no cluster | `kubectl --context "$CTX" -n production get secret <nome> -o jsonpath='{.data.<CHAVE>}' \| base64 -d` (exibe o valor em texto; use com cuidado). |

Documentação relacionada:
[k8s/argocd/README.md](../../../argocd/README.md) e
[docs/kubernetes-kustomize.md](../../../../docs/kubernetes-kustomize.md).
