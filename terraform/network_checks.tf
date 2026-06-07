# Validates public_subnet_id can reach the internet for userdata dnf (IGW or NAT),
# unless mongodb_install_via_runner is enabled.

data "aws_subnet" "public" {
  id = var.public_subnet_id
}

data "aws_route_tables" "public" {
  vpc_id = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [var.public_subnet_id]
  }
}

data "aws_route_table" "public" {
  route_table_id = one(data.aws_route_tables.public.ids)
}

locals {
  subnet_has_nat = length([
    for r in data.aws_route_table.public.routes :
    r.nat_gateway_id
    if r.cidr_block == "0.0.0.0/0" && try(r.nat_gateway_id, "") != ""
  ]) > 0

  subnet_has_igw = length([
    for r in data.aws_route_table.public.routes :
    r.gateway_id
    if r.cidr_block == "0.0.0.0/0" && try(r.gateway_id, "") != "" && startswith(r.gateway_id, "igw-")
  ]) > 0

  subnet_has_outbound = local.subnet_has_nat || local.subnet_has_igw
}

resource "terraform_data" "public_subnet_az_check" {
  lifecycle {
    precondition {
      condition     = data.aws_subnet.public.availability_zone == var.availability_zone
      error_message = "public_subnet_id must be in availability_zone ${var.availability_zone} (subnet is ${data.aws_subnet.public.availability_zone})."
    }
  }
}

check "public_subnet_outbound" {
  assert {
    condition = (
      var.mongodb_install_via_runner
      || var.skip_subnet_egress_check
      || local.subnet_has_outbound
    )
    error_message = <<-EOT
      Subnet ${var.public_subnet_id} has no 0.0.0.0/0 route to an Internet Gateway or NAT gateway.
      MongoDB userdata runs dnf install on first boot and needs outbound HTTPS.

      Fix one of:
        1. Use a public subnet with 0.0.0.0/0 → igw-* and mongodb_associate_public_ip = true, or
        2. Use a subnet with 0.0.0.0/0 → NAT gateway, or
        3. Set mongodb_install_via_runner = true, or
        4. Set skip_subnet_egress_check = true
    EOT
  }
}

check "public_subnet_igw_needs_public_ip" {
  assert {
    condition = (
      var.mongodb_install_via_runner
      || var.skip_subnet_egress_check
      || local.subnet_has_nat
      || !local.subnet_has_igw
      || var.mongodb_associate_public_ip
    )
    error_message = <<-EOT
      Subnet ${var.public_subnet_id} routes via Internet Gateway only.
      Set mongodb_associate_public_ip = true so MongoDB instances can reach repo.mongodb.com for userdata install.
    EOT
  }
}
