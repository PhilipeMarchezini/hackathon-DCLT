resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-cache"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "postgres" {
  name   = "${var.name}-postgres"
  vpc_id = var.vpc_id
  ingress {
    description     = "PostgreSQL somente a partir dos workloads EKS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.source_sg_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "redis" {
  name   = "${var.name}-redis"
  vpc_id = var.vpc_id
  ingress {
    description     = "Redis somente a partir dos workloads EKS"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.source_sg_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "postgres" {
  for_each = {
    ngo      = "ngo_db"
    donation = "donation_db"
  }
  identifier                   = "${var.name}-${each.key}"
  engine                       = "postgres"
  engine_version               = "16.4"
  instance_class               = "db.t3.micro"
  allocated_storage            = 20
  max_allocated_storage        = 50
  storage_type                 = "gp3"
  storage_encrypted            = true
  snapshot_identifier          = lookup(var.snapshot_identifiers, each.key, null)
  db_name                      = contains(concat(keys(var.snapshot_identifiers), keys(var.automated_backup_arns)), each.key) ? null : each.value
  username                     = contains(concat(keys(var.snapshot_identifiers), keys(var.automated_backup_arns)), each.key) ? null : var.database_username
  password                     = contains(concat(keys(var.snapshot_identifiers), keys(var.automated_backup_arns)), each.key) ? null : var.database_password
  db_subnet_group_name         = aws_db_subnet_group.this.name
  vpc_security_group_ids       = [aws_security_group.postgres.id]
  publicly_accessible          = false
  multi_az                     = false
  backup_retention_period      = 7
  backup_window                = "03:00-04:00"
  deletion_protection          = false
  skip_final_snapshot          = true
  performance_insights_enabled = false
  apply_immediately            = true
  tags                         = { Name = "${var.name}-${each.key}", Service = "${each.key}-service" }

  dynamic "restore_to_point_in_time" {
    for_each = contains(keys(var.automated_backup_arns), each.key) ? [var.automated_backup_arns[each.key]] : []
    content {
      source_db_instance_automated_backups_arn = restore_to_point_in_time.value
      use_latest_restorable_time               = true
    }
  }
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.name}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  port                 = 6379
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.redis.id]
  tags                 = { Name = "${var.name}-redis", Service = "donation-service" }
}

resource "aws_dynamodb_table" "volunteers" {
  count        = var.manage_dynamodb_table ? 1 : 0
  name         = "SolidaryTechVolunteers"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "volunteer_id"
  attribute {
    name = "volunteer_id"
    type = "S"
  }
  attribute {
    name = "ngo_id"
    type = "N"
  }
  global_secondary_index {
    name = "ngo_id-index"
    key_schema {
      attribute_name = "ngo_id"
      key_type       = "HASH"
    }
    projection_type = "ALL"
  }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
  replica {
    region_name            = var.dr_region
    point_in_time_recovery = true
    propagate_tags         = true
  }
  tags = { Name = "SolidaryTechVolunteers", Service = "volunteer-service" }
}

data "aws_dynamodb_table" "volunteers" {
  count = var.manage_dynamodb_table ? 0 : 1
  name  = "SolidaryTechVolunteers"
}
