output "mongodb_connection_string" {
  description = "MongoDB connection URI with credentials (private IPs — use from runner)"
  value       = module.mongodb_rs.connection_string
  sensitive   = true
}

output "runner_public_ip" {
  description = "Runner instance public IP"
  value       = module.runner.public_ip
}

output "runner_private_ip" {
  description = "Runner instance private IP"
  value       = module.runner.private_ip
}

output "mongodb_private_ips" {
  description = "MongoDB replica set private IPs"
  value       = module.mongodb_rs.private_ips
}

output "mongodb_public_ips" {
  description = "MongoDB replica set public IPs (when mongodb_associate_public_ip is true)"
  value       = module.mongodb_rs.public_ips
}

output "public_subnet_id" {
  description = "Subnet used for runner and MongoDB nodes"
  value       = var.public_subnet_id
}

output "ec2_ssh_key_pair_name" {
  description = "EC2 key pair attached to instances"
  value       = local.ec2_key_name
}

output "ssh_runner" {
  description = "SSH command for the benchmark runner"
  value       = "ssh -i ${var.private_key_path} ec2-user@${module.runner.public_ip}"
}

output "ssh_mongodb_primary" {
  description = "SSH to MongoDB primary via runner jump host"
  value       = "ssh -i ${var.private_key_path} -J ec2-user@${module.runner.public_ip} ec2-user@${module.mongodb_rs.primary_private_ip}"
}

output "mongodb_connection_string_from_runner" {
  description = "MongoDB URI for k6 / generate.py on the runner"
  value       = module.mongodb_rs.connection_string
  sensitive   = true
}

output "subnet_has_internet_egress" {
  description = "Whether public_subnet_id has 0.0.0.0/0 via IGW or NAT"
  value       = local.subnet_has_outbound
}

output "subnet_uses_igw" {
  description = "Whether the subnet default route uses an Internet Gateway"
  value       = local.subnet_has_igw
}

output "mongodb_install_method" {
  description = "How MongoDB packages are installed on DB nodes"
  value       = var.mongodb_install_via_runner ? "runner (RPM copy via SSH)" : "userdata (dnf on each node)"
}

output "rs_initiate_mongosh_eval" {
  description = "rs.initiate() body — run manually on the runner via mongosh --eval (see post_apply_checklist)"
  value       = <<-EOT
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "${module.mongodb_rs.private_ips[0]}:27017", priority: 2 },
    { _id: 1, host: "${module.mongodb_rs.private_ips[1]}:27017", priority: 1 },
    { _id: 2, host: "${module.mongodb_rs.private_ips[2]}:27017", priority: 1 }
  ]
})
EOT
}

output "post_apply_checklist" {
  description = "Operator steps after terraform apply (rs.initiate remains manual)"
  value       = <<-EOT
After terraform apply:

1. Wait for runner bootstrap (~5–15 min):
   ssh -i <pem> ec2-user@${module.runner.public_ip} 'test -f /var/log/acid-scale-runner-ready.log && /usr/local/bin/k6 version'

2. Confirm mongod on all MongoDB nodes (from runner):
   for ip in ${join(" ", module.mongodb_rs.private_ips)}; do timeout 2 bash -c "echo >/dev/tcp/$ip/27017" && echo OK $ip; done

3. MANUAL — initialize replica set from the runner:
   export MONGO_ADMIN_PASSWORD='<from tfvars>'
   export MONGO_MEMBER_0=${module.mongodb_rs.private_ips[0]} MONGO_MEMBER_1=${module.mongodb_rs.private_ips[1]} MONGO_MEMBER_2=${module.mongodb_rs.private_ips[2]}
   bash ~/ACID@Scale/scripts/rs_initiate.sh
   # Or: mongosh to node 0 with: terraform output -raw rs_initiate_mongosh_eval

4. Set MONGO_URI (sensitive): terraform output -raw mongodb_connection_string

5. Copy project to runner, seed, verify, run benchmarks (see README.md).
EOT
}
