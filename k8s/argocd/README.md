# Argo CD somente no EKS

Este laboratorio usa uma unica Application, sem App of Apps nem AppProjects
adicionais. O nome `production` identifica o ambiente AWS academico, nao uma
configuracao completa de alta disponibilidade para producao comercial.

```text
Terraform -> VPC, EKS, RDS, Valkey, SQS, DynamoDB e ECR
          -> Helm: Argo CD, metrics-server, Traefik e Sealed Secrets
Argo CD   -> k8s/overlays/production -> microsservicos
Minikube  -> kubectl apply -k k8s/overlays/development (sem Argo CD)
```

## Getting started (resumo)

Pre-requisitos: AWS CLI com o profile `aws-lab` valido, Terraform, `kubectl`
e `kubeseal` (`brew install kubeseal`). As secoes seguintes detalham cada passo.

```bash
# 1. Infraestrutura + Argo CD, metrics-server, Traefik e Sealed Secrets
export AWS_PROFILE=aws-lab
cd terraform/environments/production
terraform init
terraform apply -target=module.eks   # primeira vez: o provider Helm depende do EKS
terraform apply
cd -

# 2. Acesso ao cluster
aws eks update-kubeconfig --name toggle-master-eks --region us-east-1 --profile aws-lab
export CTX=arn:aws:eks:us-east-1:042444213801:cluster/toggle-master-eks
kubectl --context "$CTX" -n argocd get pods

# 3. Imagens no ECR e SealedSecrets no Git (ver ../README.md), depois commit e push

# 4. Registrar a Application (uma vez)
kubectl --context "$CTX" apply -f k8s/argocd/application.yaml

# 5. Abrir a UI em https://localhost:8443 (usuario admin)
kubectl --context "$CTX" -n argocd port-forward svc/argocd-server 8443:443
kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Na UI, abra `togglemaster-production` e clique em **Sync**. O resultado
esperado e `Synced/Healthy` (secao 5).

## Arquivos e responsabilidades

- [values.yaml](values.yaml): configuracao do release Argo CD no EKS.
- [application.yaml](application.yaml): Application `togglemaster-production`.
- [Terraform de producao](../../terraform/environments/production/main.tf):
  instala os quatro charts (Argo CD, metrics-server, Traefik e Sealed Secrets).
  Nao os instale novamente pelo Argo CD.
- [update-gitops.yml](../../.github/workflows/update-gitops.yml): atualiza as
  tags de imagem no overlay apos o CI (secao 4).

O Argo CD fica como ClusterIP, sem Ingress, com HTTPS habilitado.
Server, repo-server e ApplicationSet usam duas replicas; Redis usa uma.
Isso nao representa uma instalacao totalmente HA.

## 1. Provisionar a plataforma

Siga o [README do Terraform](../../terraform/README.md). Em um cluster novo,
crie primeiro o EKS e depois rode o apply completo para os releases Helm.
O chart Traefik fixado requer Kubernetes >= 1.30.

```bash
export AWS_PROFILE=aws-lab
aws eks update-kubeconfig --name toggle-master-eks --region us-east-1 --profile aws-lab
export CTX=arn:aws:eks:us-east-1:042444213801:cluster/toggle-master-eks

kubectl --context "$CTX" get nodes
kubectl --context "$CTX" -n argocd get pods
kubectl --context "$CTX" top nodes
kubectl --context "$CTX" -n traefik get service traefik
```

Traefik cria um Service LoadBalancer com NLB publico nas subnets publicas.
Usamos o provisionamento legado do EKS (`aws-load-balancer-type: nlb`), sem
AWS Load Balancer Controller nem EKS Auto Mode. A identidade/roles do lab
precisam permitir o provisionamento do NLB; um endereco pendente exige
inspecionar os eventos do Service. Ha cobranca pelo balanceador.
O HTTP publico da aplicacao e apenas para o lab; nao envie credenciais reais
por ele. Para uso real, configure dominio e TLS.

Antes de instalar, confirme que metrics-server/Traefik nao sao gerenciados
por outro Helm release, addon ou Application. Nao adote releases existentes
sem verificar o state e a propriedade dos recursos.

## 2. Preparar a aplicacao

**Nao sincronize antes destes passos:**

1. Publique as cinco imagens no ECR e atualize o overlay com tags imutaveis.
   Apos o merge em `main`, o CI faz isso por servico (secao 4); antes disso,
   siga o processo manual do [README do Kubernetes](../README.md).
2. Gere os seis SealedSecrets com o `kubeseal` usando o certificado do
   controller deste cluster (ver [README do Kubernetes](../README.md)).
3. Rotacione valores que ja foram versionados em texto puro. Remover arquivos
   nao remove credenciais do historico do Git.
4. Faca commit e push das alteracoes. A Application acompanha `feature/argocd`;
   depois do merge, ajuste `targetRevision` para a branch desejada.

O Argo CD nao constroi imagens nem provisiona bancos AWS. Ele aplica os
SealedSecrets; o controller sealed-secrets cria os Secrets no cluster.
O projeto `default` e adequado ao escopo deste lab de um unico ambiente.

## 3. Acessar o Argo CD

```bash
kubectl --context "$CTX" -n argocd port-forward svc/argocd-server 8443:443
```

Acesse <https://localhost:8443>, com certificado autoassinado.
Em outro terminal, obtenha a senha inicial (nao a copie para o Git):

```bash
kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Entre como `admin`, troque a senha e remova o Secret inicial apos a troca.

## 4. Registrar e sincronizar

Na raiz do repositorio:

```bash
kubectl --context "$CTX" apply -f k8s/argocd/application.yaml
```

Na interface, abra `togglemaster-production`, revise o diff e clique em
**Sync**, sem marcar **Prune**. Nao use sync seletivo de recursos: hooks
nao executam em sync seletivo.

O sync e manual: pushes tornam a Application OutOfSync, mas nao aplicam
nem removem recursos automaticamente.

### Publicacao de tags pelo CI

O CI publica imagens e registra a nova tag no Git; o Argo CD continua sendo
o unico responsavel por aplicar no cluster.

```text
push em main (codigo do servico X)
  -> <servico>-ci.yml: lint, seguranca, build e push no ECR (sha-<commit>)
  -> update-gitops.yml: kustomize edit set image X -> build -> commit em main
  -> Argo CD: OutOfSync -> Sync (manual neste lab)
```

Os cinco workflows de servico em [`.github/workflows`](../../.github/workflows)
executam lint, verificacoes de seguranca e build. Em pull requests, o build
nao usa credenciais AWS, nao publica imagens e nao altera manifests.

Depois de um build publicado em `main`, cada workflow chama
[`update-gitops.yml`](../../.github/workflows/update-gitops.yml), que executa
[`update-gitops.sh`](../../.github/scripts/update-gitops.sh):

1. Recebe o registry do ECR e a tag `sha-<SHA completo do commit>`, publicada
   pelo build. O CI publica somente essa tag, sem `latest`, e o overlay usa
   a mesma tag `sha-...`.
2. Atualiza somente a imagem do respectivo servico no overlay de producao.
3. Executa `kustomize build` **antes** do commit/push; uma falha bloqueia a publicacao.
4. Faz commit e push somente do `kustomization.yaml` em `main`.
   Se outro servico publicar ao mesmo tempo, refaz a alteracao na versao mais
   recente de `main`, sem force push. Builds com codigo do servico desatualizado
   sao rejeitados.
5. Registra imagem, resultado e commit no resumo da execucao.

O workflow tambem executa testes de integracao em repositorios Git temporarios
antes de atualizar `main`. Para roda-los localmente, com Python 3, Git e
Kustomize 5.8.1 no `PATH`:

```bash
python3 .github/scripts/tests/test_update_gitops.py -v
```

Configure os secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e
`AWS_SESSION_TOKEN` do laboratorio no GitHub e renove-os quando expirarem.
O job de atualizacao precisa de `GITHUB_TOKEN` com `contents: write`;
as regras de protecao de `main` tambem precisam permitir esse push.
Se a branch exigir PR para toda alteracao, sera necessario um fluxo via PR
em vez de habilitar bypass indiscriminado.

Commits automaticos mudam apenas o overlay, fora dos filtros de caminhos dos
workflows de servico, e pushes com `GITHUB_TOKEN` nao disparam novos workflows
de push. Nao ha loop de builds.

Problemas comuns:

| Sintoma | Causa provavel |
|---|---|
| Build falha no login/push do ECR | Credenciais do AWS Academy expiradas nos secrets do GitHub |
| `Newer changes exist for <servico>` | Outro commit mais novo do servico esta em `main`; o CI dele publica a tag correta |
| Push rejeitado apos 10 tentativas | Protecao de branch ou token sem `contents: write` |
| Application nao fica OutOfSync | `targetRevision` ainda aponta para `feature/argocd`, ou use **Refresh** |

O Terraform mantem os repositorios ECR com
`image_tag_mutability = "IMMUTABLE"`. As tags por commit evitam reutilizar
`latest` entre builds de commits diferentes e identificam a versao implantada.

**Neste momento, o CI atualiza `main`, mas a Application ainda acompanha
`feature/argocd`.** Nenhuma mudanca e aplicada ao cluster por esse fluxo.
Depois do merge e da revisao dos manifests, ajuste `targetRevision` para
`main` e aplique a Application. O sync continua manual; o CI nao chama
`argocd app sync` e nao habilita `automated` nem `selfHeal`.

Ordem dentro da unica Application:

1. Wave 0: Namespace, ConfigMaps, SealedSecrets, Services, Middleware e Ingress.
2. Wave 1: Job `postgres-schema-init`, hook **Sync**, usando o ConfigMap
   e o Secret ja disponiveis.
3. Wave 2: Deployments e HPAs, somente apos o sucesso do Job.

O hook nao e PreSync: no primeiro deploy, os scripts ainda nao existiriam.
`BeforeHookCreation` recria o Job em cada sync completo, evitando erros
de campos imutaveis. SQL cria bancos somente se ausentes; erros reais
interrompem o Job e o sync. O ultimo Job fica disponivel para logs.

O HPA controla replicas. `ignoreDifferences` com
`RespectIgnoreDifferences=true` evita que o Argo CD reverta esse valor.

## 5. Validar

```bash
kubectl --context "$CTX" -n argocd get application togglemaster-production
kubectl --context "$CTX" -n production get pods,hpa,ingress
kubectl --context "$CTX" -n production logs job/postgres-schema-init
```

Depois de gerar a API key no auth-service, atualize `SERVICE_API_KEY` no
SealedSecret com `kubeseal --merge-into`, faca commit, sincronize e reinicie
evaluation-service (instrucoes no README do Kubernetes).

Traefik preserva as URLs `/auth-service/...`, `/flag-service/...` etc.,
removendo o prefixo antes de enviar ao microsservico. Valide com:

```bash
LB=$(kubectl --context "$CTX" -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl --fail "http://$LB/auth-service/health"
```

O resultado esperado e `Synced/Healthy`, com HPAs recebendo metricas.
O Argo CD consulta o Git periodicamente; use **Refresh** para antecipar.

## Migracao da estrutura anterior

Os roots e as Applications de plataforma anteriores foram removidos apenas
dos arquivos. Isso **nao desinstala nada dos clusters**.

- No Minikube, desenvolvimento passa a usar os addons e `kubectl`, sem Argo CD.
  Se optar por recriar o cluster, lembre que isso apaga os dados locais.
- Se ja houver App of Apps no EKS, desative a automacao do root antigo antes
  da migracao e retire as Applications antigas sem cascade/finalizer.
  Remover uma Application com cascade pode apagar o workload.
- Confirme que nao restou um root reconciliando os caminhos antigos, nem
  outro gerenciador dos charts que agora pertencem ao Terraform.
- Nao aplique a Application de development no EKS.

Apagar `togglemaster-production` nao apaga os workloads: a Application nao
tem finalizer de exclusao em cascata. O Terraform continua dono da plataforma.
