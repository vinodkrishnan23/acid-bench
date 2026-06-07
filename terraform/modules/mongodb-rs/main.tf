resource "aws_security_group" "mongodb" {
  name        = "${var.name_prefix}-mongodb-sg"
  description = "MongoDB replica set - SSH and mongod from runner"
  vpc_id      = var.vpc_id

  ingress {
    description     = "SSH from runner only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.runner_security_group_id]
  }

  ingress {
    description     = "mongod from runner"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [var.runner_security_group_id]
  }

  ingress {
    description = "mongod intra-RS"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-mongodb-sg"
  }
}

locals {
  mongo_private_ips = [
    for i in range(var.node_count) : cidrhost(
      data.aws_subnet.selected.cidr_block,
      var.private_ip_hostnums[i]
    )
  ]
}

resource "aws_iam_role" "mongodb" {
  name = "${var.name_prefix}-mongodb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mongodb_ssm" {
  role       = aws_iam_role.mongodb.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "mongodb" {
  name = "${var.name_prefix}-mongodb-profile"
  role = aws_iam_role.mongodb.name
}

resource "aws_instance" "mongodb" {
  count = var.node_count

  ami                         = var.ami_id
  instance_type               = "r7i.4xlarge"
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  private_ip                  = local.mongo_private_ips[count.index]
  vpc_security_group_ids      = [aws_security_group.mongodb.id]
  iam_instance_profile        = aws_iam_instance_profile.mongodb.id
  availability_zone           = var.availability_zone
  associate_public_ip_address = var.associate_public_ip_address

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  user_data = var.mongodb_install_via_runner ? base64encode(templatefile("${path.module}/userdata-bootstrap.sh.tpl", {
    node_index = count.index
    })) : base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    is_init_node         = count.index == 0
    mongo_admin_user     = var.mongo_admin_user
    mongo_admin_password = var.mongo_admin_password
  }))

  tags = {
    Name  = "${var.name_prefix}-mongodb-${count.index}"
    Role  = "mongodb-rs"
    Index = count.index
  }

  lifecycle {
    create_before_destroy = true
  }

  user_data_replace_on_change = true
}

resource "aws_volume_attachment" "mongodb_data" {
  count = var.node_count

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.mongodb_data[count.index].id
  instance_id = aws_instance.mongodb[count.index].id
}

resource "aws_ebs_volume" "mongodb_data" {
  count = var.node_count

  availability_zone = var.availability_zone
  type              = "gp3"
  size              = 1500
  encrypted         = true
  iops              = 16000
  throughput        = 1000

  tags = {
    Name = "${var.name_prefix}-mongodb-data-${count.index}"
  }
}

# Install MongoDB on private nodes without NAT: download RPMs on runner, pipe to DB nodes via SSH jump.
resource "null_resource" "mongodb_install_from_runner" {
  count = var.mongodb_install_via_runner ? 1 : 0

  depends_on = [aws_instance.mongodb, aws_volume_attachment.mongodb_data]

  triggers = {
    instance_ids = join(",", aws_instance.mongodb[*].id)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = templatefile("${path.module}/install-via-runner.sh.tpl", {
      private_key_path     = var.private_key_path
      runner_public_ip     = var.runner_public_ip
      mongo_private_ips    = join(" ", local.mongo_private_ips)
      mongo_member_0       = local.mongo_private_ips[0]
      mongo_member_1       = local.mongo_private_ips[1]
      mongo_member_2       = local.mongo_private_ips[2]
      mongo_admin_user     = var.mongo_admin_user
      mongo_admin_password = var.mongo_admin_password
    })
  }
}

