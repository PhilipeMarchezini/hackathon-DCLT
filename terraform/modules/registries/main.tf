resource "aws_ecr_repository" "this" {
  for_each             = var.manage_ecr_repositories ? toset(var.services) : toset([])
  name                 = "solidarytech/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  tags = { Service = each.value }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({ rules = [{
    rulePriority = 1
    description  = "Manter as dez imagens mais recentes"
    selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
    action       = { type = "expire" }
  }] })
}

data "aws_ecr_repository" "existing" {
  for_each = var.manage_ecr_repositories ? toset([]) : toset(var.services)
  name     = "solidarytech/${each.value}"
}

resource "aws_ecr_lifecycle_policy" "existing" {
  for_each   = data.aws_ecr_repository.existing
  repository = each.value.name
  policy = jsonencode({ rules = [{
    rulePriority = 1
    description  = "Manter as dez imagens mais recentes"
    selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
    action       = { type = "expire" }
  }] })
}
