# Argo CD somente no EKS

Este laboratorio usa uma unica Application, sem App of Apps nem AppProjects
adicionais. O nome `production` identifica o ambiente AWS academico, nao uma
configuracao completa de alta disponibilidade para producao comercial.

```text
Terraform -> VPC, EKS, RDS, Valkey, SQS, DynamoDB e ECR
          -> Helm: Argo CD, metrics-server e Traefik
Argo CD   -> k8s/overlays/production -> microsservicos
Minikube  -> kubectl apply -k k8s/overlays/development (sem Argo CD)
```

## Arquivos e responsabilidades

- [values.yaml](values.yaml): configuracao do release Argo CD no EKS.
- [application.yaml](application.yaml): Application `togglemaster-production`.
- [Terraform de producao](../../terraform/environments/production/main.tf):
  instala os tres charts. Nao os instale novamente pelo Argo CD.

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

1. Publique as cinco imagens no ECR e atualize o overlay com tags imutaveis,
   conforme o [README do Kubernetes](../README.md).
2. Preencha e aplique os seis Secrets a partir do modelo local ignorado pelo Git.
   Use endpoints da conta atual e credenciais AWS temporarias validas.
3. Rotacione valores que ja foram versionados. Remover arquivos nao remove
   credenciais do historico do Git.
4. Faca commit e push das alteracoes. A Application acompanha `feature/argocd`;
   depois do merge, ajuste `targetRevision` para a branch desejada.

O Argo CD nao constroi imagens, nao provisiona bancos AWS nem gera Secrets.
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

Ordem dentro da unica Application:

1. Wave 0: Namespace, ConfigMaps, Services, Middleware e Ingress.
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

Depois de gerar a API key no auth-service, atualize `SERVICE_API_KEY`
no arquivo local de Secrets e reaplique-o. Reinicie evaluation-service
para carregar o valor novo (instrucoes no README do Kubernetes).

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
