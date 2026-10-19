output "endpoint" {
  value = aws_db_instance.this.endpoint
}

output "arn" {
  value = aws_db_instance.this.arn
}

output "id" {
  value = aws_db_instance.this.id
}

output "subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

output "security_group_id" {
  value = aws_security_group.rds.id
}
