variable "services" { type = list(string) }
variable "manage_ecr_repositories" {
  type    = bool
  default = true
}
