variable "aws_region" {
  description = "AWS region where the existing VPC and subnets live."
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for all instances (benchmark target: ap-south-1a)."
  type        = string
}

variable "vpc_id" {
  description = "Existing VPC ID."
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet in availability_zone — runner and all 3 MongoDB nodes (route to Internet Gateway)."
  type        = string
}

variable "ami_id" {
  description = "Amazon Linux 2023 AMI ID in aws_region."
  type        = string
}

variable "key_name" {
  description = "Existing EC2 key pair name in AWS. Ignored when ssh_public_key_file is set."
  type        = string
  default     = null
  nullable    = true
}

variable "ssh_public_key_file" {
  description = "Path to SSH public key (.pub). Terraform creates aws_key_pair when set."
  type        = string
  default     = null
  nullable    = true
}

variable "ec2_key_pair_name" {
  description = "AWS key pair name when ssh_public_key_file is set; defaults to \"<name_prefix>-ec2-key\"."
  type        = string
  default     = null
  nullable    = true
}

variable "private_key_path" {
  description = "Local path to the private .pem matching the EC2 key pair (SSH and optional mongodb_install_via_runner)."
  type        = string
}

variable "mongo_admin_user" {
  description = "MongoDB admin username created on node 0."
  type        = string
}

variable "mongo_admin_password" {
  description = "MongoDB admin password."
  type        = string
  sensitive   = true
}

variable "ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to the runner."
  type        = list(string)
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "extra_tags" {
  description = "Tags applied to all resources (merged with Project/ManagedBy via provider default_tags)."
  type        = map(string)
}

variable "mongodb_associate_public_ip" {
  description = "Assign a public IPv4 to each MongoDB instance (required for userdata dnf when subnet uses IGW only)."
  type        = bool
}

variable "mongodb_install_via_runner" {
  description = "If true, mount EBS in userdata only; install MongoDB RPMs from the runner."
  type        = bool
}

variable "skip_subnet_egress_check" {
  description = "Skip plan-time check for internet egress on public_subnet_id."
  type        = bool
}

variable "mongodb_private_ip_hostnums" {
  description = "Three unused host indices in public_subnet CIDR for stable MongoDB private IPs (e.g. [50, 51, 52])."
  type        = list(number)
}

