# Register an SSH public key in AWS for EC2 instances. The private .pem stays on your machine only.
#
# From an existing .pem:
#   ssh-keygen -y -f /path/to/my-key.pem > /path/to/my-key.pub
# Then set ssh_public_key_file in terraform.tfvars (or use key_name for an existing pair).

resource "aws_key_pair" "managed" {
  count = var.ssh_public_key_file != null ? 1 : 0

  key_name   = var.ec2_key_pair_name != null ? var.ec2_key_pair_name : "${var.name_prefix}-ec2-key"
  public_key = file(var.ssh_public_key_file)
}

resource "terraform_data" "ssh_key_check" {
  lifecycle {
    precondition {
      condition     = var.key_name != null || var.ssh_public_key_file != null
      error_message = "Set key_name or ssh_public_key_file in terraform.tfvars."
    }
  }
}
