locals {
  ec2_key_name = coalesce(
    var.key_name,
    try(aws_key_pair.managed[0].key_name, null)
  )

  default_tags = merge(var.extra_tags, {
    Project   = "fss-q1-demo"
    ManagedBy = "terraform"
  })
}
