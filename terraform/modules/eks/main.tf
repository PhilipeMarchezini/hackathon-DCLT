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
