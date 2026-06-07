# Terraform — FSS Q1 demo

**Do not commit** `terraform.tfvars`, `*.auto.tfvars`, or `*.pem`. Copy from `terraform.tfvars.example`.

## What Terraform automates

| Component | Automated |
|-----------|-----------|
| Runner `c6i.8xlarge` | Yes — public IP, SG, userdata |
| 3× MongoDB `r6i.2xlarge` | Yes — EBS data volumes, Enterprise 8.0.23, `mongod.conf`, `mongod` service |
| Admin user on node 0 | Yes — created in userdata (or install-via-runner path) |
| Custom k6 + `k6/x/mongo` on runner | Yes — `xk6 build v0.57.0` + xk6-mongo, `/usr/local/bin/k6`, `/etc/profile.d/acid-scale.sh` |
| Python 3.11, pymongo, faker, mongosh, git on runner | Yes |
| Kernel tuning / ulimits on runner | Yes |
| **`rs.initiate()`** | **No — manual** (documented below) |

## Network

Set **`public_subnet_id`** in `terraform.tfvars` — **one public subnet in `availability_zone`** (e.g. `ap-south-1a`) for:

- 1× benchmark **runner** (public IP)
- 3× **MongoDB** nodes (public IP when `mongodb_associate_public_ip = true`)

Subnet route table must have **`0.0.0.0/0` → Internet Gateway** (typical public subnet) or **NAT gateway**.

## Authentication

Set **`aws_profile`** (SSO) or optional keys in tfvars — see `terraform.tfvars.example`.

## Apply

```bash
aws sso login --profile <your-aws-profile>
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Set public_subnet_id, vpc_id, ami_id, keys, mongo_admin_password, ssh_cidrs, ...
terraform init && terraform plan && terraform apply
```

After apply:

```bash
terraform output post_apply_checklist
terraform output -raw rs_initiate_mongosh_eval   # paste into mongosh on runner
terraform output -raw mongodb_connection_string  # sensitive — for MONGO_URI
```

## After apply: manual `rs.initiate()`

Terraform starts `mongod` on three nodes and creates the admin user on node 0, but **does not** run `rs.initiate()`.

From the **runner** (after all nodes accept TCP 27017):

```bash
export MONGO_ADMIN_PASSWORD='...'   # from terraform.tfvars
# Use the private IPs from `terraform output mongodb_private_ips`
export MONGO_MEMBER_0=<member-0-ip> MONGO_MEMBER_1=<member-1-ip> MONGO_MEMBER_2=<member-2-ip>
bash ~/ACID@Scale/scripts/rs_initiate.sh
```

IPs: `terraform output mongodb_private_ips`. Full flow: [../README.md](../README.md) and [../spec.md](../spec.md) §1.3.1.

## Optional: MongoDB without NAT on DB nodes

Set `mongodb_install_via_runner = true` — DB userdata only mounts EBS; Terraform `null_resource` copies RPMs from the runner over SSH. **`rs.initiate()` is still manual** after install completes.

## Tags

```hcl
extra_tags = {
  purpose     = "opportunity"
  "expire-on" = "2027-01-01"
  owner       = "<your-owner-tag>"
}
```
