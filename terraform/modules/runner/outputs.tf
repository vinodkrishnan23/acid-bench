output "public_ip" {
  value = aws_instance.runner.public_ip
}

output "security_group_id" {
  description = "Runner security group — referenced by MongoDB SG for SSH and mongod"
  value       = aws_security_group.runner.id
}

output "private_ip" {
  value = aws_instance.runner.private_ip
}

output "instance_id" {
  value = aws_instance.runner.id
}
