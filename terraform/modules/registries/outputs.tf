output "repository_urls" {
  value = var.manage_ecr_repositories ? { for name, repository in aws_ecr_repository.this : name => repository.repository_url } : { for name, repository in data.aws_ecr_repository.existing : name => repository.repository_url }
}
