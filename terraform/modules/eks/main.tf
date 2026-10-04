data "aws_iam_role" "lab" { name = var.lab_role_name }

resource "aws_eks_cluster" "this" {
  name     = "${var.name}-eks"
  version  = var.cluster_version
  role_arn = data.aws_iam_role.lab.arn
  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }
  access_config { authentication_mode = "API_AND_CONFIG_MAP" }
  upgrade_policy { support_type = "STANDARD" }
  tags = { Name = "${var.name}-eks" }
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_launch_template" "workers" {
  name_prefix            = "${var.name}-workers-"
  update_default_version = true

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.resource_tags, { Name = "${var.name}-worker" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.resource_tags, { Name = "${var.name}-worker-volume" })
  }

  tags = merge(var.resource_tags, { Name = "${var.name}-workers" })
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-workers"
  node_role_arn   = data.aws_iam_role.lab.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  launch_template {
    id      = aws_launch_template.workers.id
    version = aws_launch_template.workers.latest_version
  }
  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 4
  }
  update_config { max_unavailable = 1 }
  depends_on = [aws_eks_cluster.this, aws_eks_addon.vpc_cni]
}

# O bootstrap do criador do cluster registra a role da sessão, mas no AWS Academy
# quem aplica é uma sessão assumida de voclabs, que fica sem access entry e recebe
# 401 no servidor da API. Declarar as entradas aqui mantém o acesso reproduzível
# em um novo apply ou na região de DR, em vez de depender de um comando manual.
resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.cluster_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = aws_eks_access_entry.admin
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
