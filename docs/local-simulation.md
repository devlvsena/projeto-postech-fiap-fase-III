## Baixar imagens do ECR e subir cluster local
- Conectar o docker ao ecr
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <id>.dkr.ecr.us-east-1.amazonaws.com

- Baixar imagens
docker pull --platform linux/amd64 <id>.dkr.ecr.us-east-1.amazonaws.com/analytics-service:latest
docker pull --platform linux/amd64 <id>.dkr.ecr.us-east-1.amazonaws.com/auth-service:latest
docker pull --platform linux/amd64 <id>.dkr.ecr.us-east-1.amazonaws.com/evaluation-service:latest
docker pull --platform linux/amd64 <id>.dkr.ecr.us-east-1.amazonaws.com/flag-service:latest
docker pull --platform linux/amd64 <id>.dkr.ecr.us-east-1.amazonaws.com/targeting-service:latest

- Mudar o nome da imagem para incluir no contexto do kind
docker tag <id>.dkr.ecr.us-east-1.amazonaws.com/analytics-service:latest analytics-service:latest
docker tag <id>.dkr.ecr.us-east-1.amazonaws.com/auth-service:latest auth-service:latest
docker tag <id>.dkr.ecr.us-east-1.amazonaws.com/evaluation-service:latest evaluation-service:latest
docker tag <id>.dkr.ecr.us-east-1.amazonaws.com/flag-service:latest flag-service:latest
docker tag <id>.dkr.ecr.us-east-1.amazonaws.com/targeting-service:latest targeting-service:latest


- Carregar no contexto do kind
kind load docker-image analytics-service:latest --name toggle-master-cluster
kind load docker-image auth-service:latest --name toggle-master-cluster
kind load docker-image evaluation-service:latest --name toggle-master-cluster
kind load docker-image flag-service:latest --name toggle-master-cluster
kind load docker-image targeting-service:latest --name toggle-master-cluster


docker exec -it aa8303e82f9d crictl images
docker exec -it aa8303e82f9d crictl rmi <IMAGE_ID ou nome:tag>
docker exec -it aa8303e82f9d crictl rmi analytics-service:latest
docker exec -it aa8303e82f9d crictl rmi auth-service:latest
docker exec -it aa8303e82f9d crictl rmi evaluation-service:latest
docker exec -it aa8303e82f9d crictl rmi flag-service:latest
docker exec -it aa8303e82f9d crictl rmi targeting-service:latest


helm list -n toggle-master
helm uninstall auth-service analytics-service -n toggle-master

helm upgrade --install auth-service ./charts/microsservice \
  -f ./charts/services/auth-service/values.yaml \
  -n toggle-master


---

kind create cluster --name toggle-master
docker network ls | grep kind


aws --endpoint-url=http://localhost:4566 s3 mb s3://toggle-master-tfstate-dev --region us-east-1


kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo