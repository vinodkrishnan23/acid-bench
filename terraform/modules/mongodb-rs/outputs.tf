output "private_ips" {
  description = "Private IPs of all replica set members (stable cidrhost assignments)"
  value       = local.mongo_private_ips
}

output "primary_private_ip" {
  description = "Private IP of node 0 (primary candidate)"
  value       = local.mongo_private_ips[0]
}

output "public_ips" {
  description = "Public IPs of all replica set members (null if associate_public_ip_address is false)"
  value       = aws_instance.mongodb[*].public_ip
}

output "connection_string" {
  description = "MongoDB connection string with admin credentials"
  value       = "mongodb://${var.mongo_admin_user}:${var.mongo_admin_password}@${join(",", [for ip in local.mongo_private_ips : "${ip}:27017"])}/?replicaSet=rs0&authSource=admin"
  sensitive   = true
}
