locals {
  name = "${var.project_name}-${var.environment}"
  required_tags = {
    Project     = "SolidaryTech"
    Environment = "Production"
    CostCenter  = var.cost_center
    ManagedBy   = "Terraform"
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Quem aplica no AWS Academy chega como sessão assumida de voclabs, e o
  # bootstrap do criador do cluster não registra essa identidade. Sem uma access
  # entry para ela, o kubectl e o provider helm recebem 401 e o cluster nasce
  # inacessível. Derivar a role da própria sessão evita depender de alguém
  # lembrar de preencher cluster_admin_principal_arns a cada novo laboratório.
  # arn:aws:sts::<conta>:assumed-role/<role>/<sessão> vira arn:aws:iam::<conta>:role/<role>
  caller_is_assumed_role = can(regex("^arn:aws:sts::[0-9]+:assumed-role/", data.aws_caller_identity.current.arn))
  caller_role_arn = local.caller_is_assumed_role ? format(
    "arn:aws:iam::%s:role/%s",
    data.aws_caller_identity.current.account_id,
    split("/", data.aws_caller_identity.current.arn)[1]
  ) : data.aws_caller_identity.current.arn

  cluster_admins = length(var.cluster_admin_principal_arns) > 0 ? var.cluster_admin_principal_arns : [local.caller_role_arn]
}

module "network" {
  source             = "./modules/network"
  name               = local.name
  cidr               = var.vpc_cidr
  availability_zones = var.availability_zones
  cluster_name       = "${local.name}-eks"
}

module "eks" {
  source                       = "./modules/eks"
  name                         = local.name
  cluster_version              = var.eks_version
  subnet_ids                   = module.network.public_subnet_ids
  lab_role_name                = var.lab_role_name
  node_instance_types          = var.node_instance_types
  resource_tags                = local.required_tags
  cluster_admin_principal_arns = local.cluster_admins
  max_pods_per_node            = var.max_pods_per_node
}

module "data" {
  source                = "./modules/data"
  name                  = local.name
  vpc_id                = module.network.vpc_id
  subnet_ids            = module.network.private_subnet_ids
  source_sg_id          = module.eks.cluster_security_group_id
  database_username     = var.database_username
  database_password     = var.database_password
  snapshot_identifiers  = var.database_snapshot_identifiers
  automated_backup_arns = var.database_automated_backup_arns
  dr_region             = var.dr_region
  manage_dynamodb_table = var.manage_dynamodb_table
}

module "messaging" {
  source = "./modules/messaging"
  name   = local.name
}

module "registries" {
  source                  = "./modules/registries"
  services                = ["ngo-service", "donation-service", "volunteer-service"]
  manage_ecr_repositories = var.manage_ecr_repositories
}

resource "aws_ecr_replication_configuration" "dr" {
  count = var.create_dr_protection_resources ? 1 : 0
  replication_configuration {
    rule {
      destination {
        region      = var.dr_region
        registry_id = data.aws_caller_identity.current.account_id
      }
      repository_filter {
        filter      = "solidarytech/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

module "backup" {
  count     = var.create_dr_protection_resources ? 1 : 0
  source    = "./modules/backup"
  providers = { aws = aws.dr }
  name      = local.name
}

resource "aws_kms_key" "rds_backup" {
  count                   = var.create_dr_protection_resources ? 1 : 0
  provider                = aws.dr
  description             = "SolidaryTech cross-region RDS backups"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_db_instance_automated_backups_replication" "postgres" {
  for_each               = var.create_dr_protection_resources ? module.data.rds_arns : {}
  provider               = aws.dr
  source_db_instance_arn = each.value
  retention_period       = 7
  kms_key_id             = aws_kms_key.rds_backup[0].arn
}

locals {
  velero_bucket_name = var.create_dr_protection_resources ? module.backup[0].velero_bucket_name : var.existing_velero_bucket_name
}

module "argocd" {
  source             = "./modules/argocd"
  gitops_repository  = var.gitops_repository
  backup_bucket_name = local.velero_bucket_name
  aws_region         = var.aws_region
  dr_region          = var.dr_region
  depends_on         = [module.eks]
}
