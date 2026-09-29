variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "source_sg_id" { type = string }
variable "database_username" { type = string }
variable "database_password" {
  type      = string
  sensitive = true
}
variable "snapshot_identifiers" {
  type    = map(string)
  default = {}
}
variable "automated_backup_arns" {
  type    = map(string)
  default = {}
}
variable "dr_region" { type = string }
variable "manage_dynamodb_table" {
  type    = bool
  default = true
}
