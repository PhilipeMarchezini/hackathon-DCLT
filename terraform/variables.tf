variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Região primária."
}
variable "dr_region" {
  type        = string
  default     = "us-west-2"
  description = "Região de DR."
}
variable "project_name" {
  type        = string
  default     = "solidarytech"
  description = "Prefixo dos recursos."
}
variable "environment" {
  type        = string
  default     = "production"
  description = "Ambiente lógico exigido pelo desafio."
}
variable "cost_center" {
  type        = string
  default     = "NGO-Core"
  description = "Centro de custo FinOps."
}
variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR da VPC."
}
variable "availability_zones" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  description = "AZs do ambiente."
}
variable "lab_role_name" {
  type        = string
  default     = "LabRole"
  description = "Role preexistente do AWS Academy."
}
variable "eks_version" {
  type        = string
  default     = "1.35"
  description = "Versão do Kubernetes no EKS."
}
variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium"]
  description = "Tipos dos nodes."
}
variable "database_username" {
  type        = string
  default     = "solidary"
  description = "Usuário master dos RDS."
}
variable "database_password" {
  type        = string
  sensitive   = true
  description = "Senha recebida por TF_VAR_database_password."
}
variable "database_snapshot_identifiers" {
  type        = map(string)
  default     = {}
  description = "Snapshots opcionais por chave ngo/donation para restauracao em DR."
  validation {
    condition     = alltrue([for key in keys(var.database_snapshot_identifiers) : contains(["ngo", "donation"], key)])
    error_message = "Use somente as chaves ngo e donation."
  }
}
variable "database_automated_backup_arns" {
  type        = map(string)
  default     = {}
  description = "ARNs dos automated backups replicados por chave ngo/donation para PITR em DR."
  validation {
    condition     = alltrue([for key in keys(var.database_automated_backup_arns) : contains(["ngo", "donation"], key)])
    error_message = "Use somente as chaves ngo e donation."
  }
}

check "exclusive_database_restore_sources" {
  assert {
    condition     = length(setintersection(toset(keys(var.database_snapshot_identifiers)), toset(keys(var.database_automated_backup_arns)))) == 0
    error_message = "Cada banco deve usar snapshot_identifier ou automated backup ARN, nunca ambos."
  }
}
variable "manage_dynamodb_table" {
  type        = bool
  default     = true
  description = "Cria a Global Table no ambiente primario; em um stack DR separado, referencia a replica existente."
}
variable "manage_ecr_repositories" {
  type        = bool
  default     = true
  description = "Cria repositórios ECR no state primário; em DR, lê repositórios já replicados."
}
variable "create_dr_protection_resources" {
  type        = bool
  default     = true
  description = "Cria bucket Velero e replicacao RDS na regiao DR; desative ao aplicar um stack de failover separado."
}
variable "existing_velero_bucket_name" {
  type        = string
  default     = ""
  description = "Bucket Velero global ja criado pelo stack primario, obrigatorio quando create_dr_protection_resources=false."
  validation {
    condition     = var.create_dr_protection_resources || length(trimspace(var.existing_velero_bucket_name)) > 0
    error_message = "Informe existing_velero_bucket_name quando create_dr_protection_resources=false."
  }
}
variable "existing_velero_bucket_region" {
  type        = string
  default     = ""
  description = "Região do bucket informado em existing_velero_bucket_name. Vazio assume aws_region. Necessário quando o bucket foi criado fora do Terraform em outra região, como no contorno do SCP do AWS Academy que bloqueia aws_s3_bucket."
}

variable "gitops_repository" {
  type        = string
  default     = "https://github.com/PhilipeMarchezini/hackathon-DCLT.git"
  description = "Repositório observado pelo ArgoCD."
}

variable "cluster_admin_principal_arns" {
  type        = list(string)
  default     = []
  description = "Roles IAM com acesso administrativo ao EKS via access entry. Vazio usa automaticamente a role da sessão que está aplicando."
}

variable "max_pods_per_node" {
  type        = number
  default     = 110
  description = "Pods por node, aplicado via NodeConfig do nodeadm. Depende da delegação de prefixo habilitada no addon vpc-cni."
}
