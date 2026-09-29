output "rds_endpoints" { value = { for name, db in aws_db_instance.postgres : name => db.address } }
output "rds_arns" { value = { for name, db in aws_db_instance.postgres : name => db.arn } }
output "redis_endpoint" { value = aws_elasticache_cluster.redis.cache_nodes[0].address }
output "dynamodb_table" {
  value = var.manage_dynamodb_table ? aws_dynamodb_table.volunteers[0].name : data.aws_dynamodb_table.volunteers[0].name
}
