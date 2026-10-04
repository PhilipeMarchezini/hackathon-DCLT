variable "name" { type = string }
variable "cluster_version" { type = string }
variable "subnet_ids" { type = list(string) }
variable "lab_role_name" { type = string }
variable "node_instance_types" { type = list(string) }
variable "resource_tags" {
  type    = map(string)
  default = {}
}
variable "cluster_admin_principal_arns" {
  type        = list(string)
  default     = []
  description = "ARNs de roles IAM que recebem AmazonEKSClusterAdminPolicy por access entry."
}
variable "max_pods_per_node" {
  type        = number
  default     = 110
  description = "Limite de pods por node. Requer delegação de prefixo no VPC CNI; 110 é o valor que a calculadora da AWS indica para t3.medium com delegação ativa."
}
