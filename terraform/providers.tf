provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.required_tags
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags {
    tags = local.required_tags
  }
}

# O token de aws_eks_cluster_auth é resolvido no plan e expira em cerca de 15
# minutos. Como o cluster e os bancos levam mais do que isso para ficarem
# prontos, o helm_release do Argo CD falhava com "cluster unreachable" no fim
# de um apply longo. O exec gera o token no momento da chamada.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}
