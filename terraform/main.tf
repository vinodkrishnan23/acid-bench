terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  profile    = var.aws_profile
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token

  default_tags {
    tags = local.default_tags
  }
}

module "runner" {
  source = "./modules/runner"

  name_prefix       = var.name_prefix
  vpc_id            = var.vpc_id
  subnet_id         = var.public_subnet_id
  availability_zone = var.availability_zone
  ami_id            = var.ami_id
  key_name          = local.ec2_key_name
  ssh_cidrs         = var.ssh_cidrs
}

module "mongodb_rs" {
  source = "./modules/mongodb-rs"

  name_prefix                 = var.name_prefix
  vpc_id                      = var.vpc_id
  subnet_id                   = var.public_subnet_id
  availability_zone           = var.availability_zone
  ami_id                      = var.ami_id
  key_name                    = local.ec2_key_name
  private_key_path            = var.private_key_path
  mongo_admin_user            = var.mongo_admin_user
  mongo_admin_password        = var.mongo_admin_password
  associate_public_ip_address = var.mongodb_associate_public_ip
  runner_public_ip            = module.runner.public_ip
  runner_security_group_id    = module.runner.security_group_id
  mongodb_install_via_runner  = var.mongodb_install_via_runner
  private_ip_hostnums         = var.mongodb_private_ip_hostnums
}
