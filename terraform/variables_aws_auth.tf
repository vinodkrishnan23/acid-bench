# Optional static credentials — leave all null to use the default chain (env vars,
# ~/.aws/credentials, SSO profile via aws_profile in terraform.tfvars, etc.).

variable "aws_profile" {
  description = "AWS CLI profile name (e.g. after aws sso login --profile <name>). Used when access keys are null."
  type        = string
  default     = null
  nullable    = true
}

variable "aws_access_key_id" {
  description = "Optional IAM access key ID. Prefer aws_profile or AWS_PROFILE for SSO."
  type        = string
  default     = null
  nullable    = true
}

variable "aws_secret_access_key" {
  description = "Optional IAM secret access key (pair with aws_access_key_id)."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
}

variable "aws_session_token" {
  description = "Optional session token for temporary credentials (STS/SSO export)."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
}
