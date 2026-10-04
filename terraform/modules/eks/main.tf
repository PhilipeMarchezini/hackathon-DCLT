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
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
  # Sem prefix delegation, o limite de pods por node vem da quantidade de IPs
  # das ENIs: um t3.medium para em 17 pods. A stack de observabilidade sozinha
  # saturava os dois nodes com a CPU em 41% e a memória em 33%, impedindo o
  # agendamento das aplicações e qualquer demonstração de HPA. Com delegação de
  # prefixo o mesmo t3.medium suporta 110 pods, o que resolve o gargalo sem
  # adicionar instâncias e sem aumentar o custo.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_launch_template" "workers" {
  name_prefix            = "${var.name}-workers-"
  update_default_version = true

  # O hop limit padrão é 1, o que impede um pod de obter token IMDSv2: o
  # volunteer-service falhava a readiness com "Unable to locate credentials" ao
  # tentar alcançar o DynamoDB. O AWS Academy não permite IRSA, então as cargas
  # dependem da LabRole entregue pelo IMDS e o limite precisa ser 2.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Ligar a delegação de prefixo no CNI não basta: o EKS deriva --max-pods dos
  # limites de ENI do tipo de instância no bootstrap do node e não refaz a conta
  # sozinho, então um t3.medium continuava parando em 17 pods. Este NodeConfig
  # declara o valor explicitamente. O AL2023 usa nodeadm, e um managed node group
  # cujo launch template não fixa uma AMI mescla este bloco com o bootstrap que a
  # própria AWS injeta.
  user_data = base64encode(<<-MIME
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          maxPods: ${var.max_pods_per_node}

    --//--
  MIME
  )

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
    desired_size = 3
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
