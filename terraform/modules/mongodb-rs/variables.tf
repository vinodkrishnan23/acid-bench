variable "name_prefix" {
  type = string
}

variable "mongodb_install_via_runner" {
  type        = bool
  description = "Install MongoDB from runner (no NAT on private DB subnet)"
  default     = false
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Public subnet for all MongoDB instances"
  type        = string
}

variable "associate_public_ip_address" {
  description = "Assign public IPv4 (needed for userdata dnf when subnet routes via IGW)"
  type        = bool
  default     = true
}

variable "availability_zone" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "key_name" {
  type = string
}

variable "private_key_path" {
  type = string
}

variable "runner_public_ip" {
  type        = string
  description = "Runner public IP — used for Terraform SSH jump when mongodb_install_via_runner is true"
}

variable "runner_security_group_id" {
  type        = string
  description = "Runner SG — allow SSH and mongod from runner only"
}

variable "mongo_admin_user" {
  type = string
}

variable "mongo_admin_password" {
  type      = string
  sensitive = true
}

variable "node_count" {
  type    = number
  default = 3
}

variable "private_ip_hostnums" {
  description = "Host indices in subnet CIDR for stable private IPs (one per member; must be unused in public_subnet_id)."
  type        = list(number)
  default     = [200, 201, 202]

  validation {
    condition     = length(var.private_ip_hostnums) == 3
    error_message = "Provide exactly three host numbers for the three replica set members."
  }
}

