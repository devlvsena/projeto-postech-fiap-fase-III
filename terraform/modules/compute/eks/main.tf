# ------------------------------------------------ Role do cluster (plano de controle)
# As roles só são criadas quando nenhum ARN é informado. Em contas que não
# permitem criar IAM (ex.: AWS Academy), passe uma role existente (LabRole).
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  count = var.cluster_role_arn == null ? 1 : 0

  name               = "${var.name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count = var.cluster_role_arn == null ? 1 : 0

  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------- Cluster
resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = coalesce(var.cluster_role_arn, try(aws_iam_role.cluster[0].arn, null))
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = var.subnet_ids
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ------------------------------------------------------ Role dos nós (workers)
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  count = var.node_role_arn == null ? 1 : 0

  name               = "${var.name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# Permissões mínimas para um nó entrar no cluster, configurar a rede dos pods
# (VPC CNI) e baixar imagens do ECR.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = var.node_role_arn == null ? toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])

  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

# ------------------------------------------------------------- Node group
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-nodes"
  node_role_arn   = coalesce(var.node_role_arn, try(aws_iam_role.node[0].arn, null))
  subnet_ids      = var.subnet_ids
  instance_types  = var.instance_types

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}