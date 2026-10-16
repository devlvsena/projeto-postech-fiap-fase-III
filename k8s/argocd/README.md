# Argo CD no cluster local

Instala o Argo CD no Minikube usando o chart oficial `argo/argo-cd`, fixado na
versão `10.10.5`. O serviço web fica como `ClusterIP`, sem expor o Argo CD na
rede; use port-forward para acessá-lo localmente.

## Pré-requisitos

- Helm 3 e `kubectl` instalados.
- Docker Desktop em execução.
- Cluster Minikube iniciado (`minikube start`).

Confirme que o contexto local existe e está acessível:

```bash
kubectl --context minikube get nodes
```

Todos os comandos abaixo especificam o contexto `minikube` para evitar aplicar
recursos acidentalmente no contexto Kubernetes atualmente selecionado.

## Instalar ou atualizar

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --kube-context minikube \
  --namespace argocd \
  --create-namespace \
  --version 10.10.5 \
  --values k8s/argocd/values.yaml
```

Verifique os pods:

```bash
kubectl --context minikube get pods -n argocd
```

## Acessar a interface

Em um terminal, encaminhe a porta HTTPS do serviço:

```bash
kubectl --context minikube port-forward \
  --namespace argocd \
  service/argocd-server 8080:443
```

Acesse <https://localhost:8080>. O certificado é autoassinado no setup local.

Para obter a senha inicial do usuário `admin`:

```bash
kubectl --context minikube get secret argocd-initial-admin-secret \
  --namespace argocd \
  --output jsonpath='{.data.password}' | base64 --decode
```

Após o primeiro login, altere a senha inicial. Esse Secret é criado pelo chart
e não deve ser copiado para este repositório.

## Criar a Application de desenvolvimento

Uma `Application` é o recurso do Argo CD que liga uma origem no Git a um destino
no cluster. A [apps/development.yaml](apps/development.yaml) instrui o Argo CD a
renderizar o overlay [k8s/overlays/development](../overlays/development) e
aplicar o resultado no namespace `development` do próprio Minikube.

### Campos da Application

| Campo | Valor | Significado |
|---|---|---|
| `metadata.namespace` | `argocd` | A Application fica no namespace do Argo CD, não no da aplicação |
| `spec.project` | `default` | Projeto sem restrições, adequado apenas para o ambiente local |
| `source.repoURL` | repositório no GitHub | O Argo CD clona o repositório remoto, não lê arquivos locais |
| `source.targetRevision` | `main` | Branch, tag ou SHA acompanhado pelo Argo CD |
| `source.path` | `k8s/overlays/development` | Diretório com `kustomization.yaml`; o Argo CD detecta o Kustomize automaticamente |
| `destination.server` | `https://kubernetes.default.svc` | O mesmo cluster onde o Argo CD está instalado |
| `destination.namespace` | `development` | Namespace padrão dos recursos sincronizados |

Como o Argo CD lê o repositório remoto, alterações locais só são consideradas
depois do `git push` para a revisão configurada em `targetRevision`.

### Réplicas controladas pelo HPA

Os Deployments têm `HorizontalPodAutoscaler`s com `minReplicas: 2` (definidos em
`k8s/base/*/hpa.yaml`), enquanto o overlay de desenvolvimento declara uma
réplica. Depois do sync, o HPA altera `spec.replicas` e, sem tratamento, o
Argo CD mostraria a aplicação como `OutOfSync` permanentemente.

Por isso, a Application declara:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas
syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true
```

- `ignoreDifferences` remove `/spec/replicas` da comparação entre Git e cluster.
- `RespectIgnoreDifferences=true` evita que o sync sobrescreva o valor definido
  pelo HPA.

### Pré-requisitos do overlay

Antes do primeiro sync, prepare o Minikube:

```bash
minikube addons enable metrics-server
minikube addons enable ingress
```

- Sem o `metrics-server`, os HPAs não recebem métricas de CPU e o Argo CD os
  marca como `Degraded`.
- Sem o addon de ingress, o Ingress `microservices` permanece `Progressing`.

O overlay usa `imagePullPolicy: Never`, então as imagens dos serviços precisam
existir dentro do Minikube. Construa-as conforme a seção "Ambiente de
desenvolvimento" do [README do Kubernetes](../README.md). O Argo CD não
constrói imagens; sem elas, os pods ficam em `ErrImageNeverPull`.

### Aplicar e sincronizar

Registre a Application no cluster:

```bash
kubectl --context minikube apply -f k8s/argocd/apps/development.yaml
```

A Application não tem `syncPolicy.automated`, portanto o Argo CD detecta as
diferenças, mas só as aplica quando você solicita o sync. Revise o que será
alterado antes de sincronizar:

```bash
argocd login localhost:8080 --username admin --insecure
argocd app diff togglemaster-development
argocd app sync togglemaster-development
```

Pela interface, abra `togglemaster-development` e use **Sync** →
**Synchronize**.

### Verificar o resultado

```bash
kubectl --context minikube get application togglemaster-development -n argocd
kubectl --context minikube get pods -n development
kubectl --context minikube get hpa -n development
```

O estado esperado é `Synced` e `Healthy`. Os dois status são independentes:

| Status | Pergunta respondida |
|---|---|
| Sync (`Synced` / `OutOfSync`) | O cluster corresponde ao Git? |
| Health (`Healthy` / `Progressing` / `Degraded`) | Os recursos estão funcionando? |

Para listar o status de cada recurso:

```bash
argocd app get togglemaster-development
```

O Argo CD consulta o Git periodicamente (cerca de 3 minutos). Para atualizar
imediatamente após um push, use **Refresh** na interface ou:

```bash
argocd app get togglemaster-development --refresh
```

### Problemas comuns

| Sintoma | Causa provável | Ação |
|---|---|---|
| Deployments `OutOfSync` com réplicas diferentes | HPA alterou `spec.replicas` | Confirme o `ignoreDifferences` na Application aplicada |
| HPAs `Degraded`, `TARGETS` com `<unknown>` | `metrics-server` ausente | `minikube addons enable metrics-server` |
| Ingress `Progressing` | Controller de ingress ausente | `minikube addons enable ingress` |
| Pods em `ErrImageNeverPull` | Imagem não existe no Minikube | Construa as imagens com `minikube image build` |
| Pods com alguns restarts após o primeiro sync | Serviços subiram antes do Postgres/Redis | Normal se o contador parar de aumentar |
| Mudança local não aparece no Argo CD | Commit não foi enviado ao GitHub | `git push` para a revisão de `targetRevision` |

### Remover a Application

```bash
kubectl --context minikube delete -f k8s/argocd/apps/development.yaml
```

Como a Application não declara o finalizer
`resources-finalizer.argocd.argoproj.io`, apagá-la remove apenas o registro no
Argo CD; os recursos do namespace `development` continuam no cluster.
