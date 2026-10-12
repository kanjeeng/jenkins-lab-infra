terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }

  # Peningkatan lanjutan: remote state terenkripsi (buat bucket dan tabel DynamoDB terlebih dahulu)
  # backend "s3" {
  #   bucket         = "NAMA-BUCKET-STATE"
  #   key            = "jenkins-lab/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-lock"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "lab"
    }
  }
}

locals {
  name = var.project_name
}

# ---------------------------------------------------------------
# Data source
# ---------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------
# Jaringan: VPC, IGW, subnet publik, route table
# ---------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false # IP publik hanya lewat Elastic IP
  tags                    = { Name = "${local.name}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group bawaan VPC dikosongkan agar tidak ada akses tak sengaja
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-default-locked" }
}

# ---------------------------------------------------------------
# Security Group (aturan dideklarasikan terpisah: tanpa circular dependency)
# ---------------------------------------------------------------
resource "aws_security_group" "jenkins" {
  name        = "${local.name}-jenkins-sg"
  description = "Server 1 Jenkins"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "jenkins-sg" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "Server 2 application host"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "app-sg" }
}

# --- jenkins-sg inbound ---
resource "aws_vpc_security_group_ingress_rule" "jenkins_ssh_dev" {
  security_group_id = aws_security_group.jenkins.id
  description       = "SSH admin dari IP pengembang"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.developer_ip_cidr
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_ui_dev" {
  security_group_id = aws_security_group.jenkins.id
  description       = "UI Jenkins dari IP pengembang"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = var.developer_ip_cidr
}

# --- jenkins-sg outbound ---
resource "aws_vpc_security_group_egress_rule" "jenkins_https_out" {
  security_group_id = aws_security_group.jenkins.id
  description       = "GitHub, Docker Hub, Discord, plugin, SSM"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "jenkins_http_out" {
  security_group_id = aws_security_group.jenkins.id
  description       = "Mirror APT Ubuntu"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "jenkins_ssh_to_app" {
  security_group_id            = aws_security_group.jenkins.id
  description                  = "Deploy ke Server 2"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.app.id
}

# --- app-sg inbound ---
resource "aws_vpc_security_group_ingress_rule" "app_ssh_from_jenkins" {
  security_group_id            = aws_security_group.app.id
  description                  = "SSH hanya dari Server 1"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.jenkins.id
}

resource "aws_vpc_security_group_ingress_rule" "app_http_public" {
  security_group_id = aws_security_group.app.id
  description       = "Aplikasi portofolio"
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
  cidr_ipv4         = "0.0.0.0/0"
}

# --- app-sg outbound ---
resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "Pull image Docker Hub dan SSM"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_http_out" {
  security_group_id = aws_security_group.app.id
  description       = "Mirror APT Ubuntu"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------
# IAM: instance profile minimum (hanya SSM Session Manager)
# ---------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------
# Key pair admin (kunci privat tidak pernah masuk state)
# ---------------------------------------------------------------
resource "aws_key_pair" "admin" {
  key_name   = "${local.name}-admin"
  public_key = file(pathexpand(var.admin_public_key_path))
}

# ---------------------------------------------------------------
# EC2: Server 1 (Jenkins) dan Server 2 (Aplikasi)
# ---------------------------------------------------------------
resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = aws_subnet.public.id
  private_ip                  = var.jenkins_private_ip
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  key_name                    = aws_key_pair.admin.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 wajib
    http_put_response_hop_limit = 1          # kontainer tidak bisa membaca IMDS
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.jenkins_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/scripts/user-data-jenkins.sh", {
    hostname       = "jenkins-controller"
    swap_size_gb   = var.swap_size_gb
    app_private_ip = var.app_private_ip
  })

  lifecycle {
    ignore_changes = [ami, user_data] # hindari penggantian server saat AMI baru terbit
  }

  tags = { Name = "${local.name}-server1-jenkins", Role = "jenkins" }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.public.id
  private_ip                  = var.app_private_ip
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = aws_key_pair.admin.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.app_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/scripts/user-data-app.sh", {
    hostname           = "app-host"
    swap_size_gb       = var.swap_size_gb
    jenkins_private_ip = var.jenkins_private_ip
    deploy_public_key  = trimspace(file(pathexpand(var.deploy_public_key_path)))
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${local.name}-server2-app", Role = "app-host" }
}

# ---------------------------------------------------------------
# Elastic IP
# ---------------------------------------------------------------
resource "aws_eip" "jenkins" {
  domain     = "vpc"
  instance   = aws_instance.jenkins.id
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${local.name}-jenkins-eip" }
}

resource "aws_eip" "app" {
  domain     = "vpc"
  instance   = aws_instance.app.id
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${local.name}-app-eip" }
}
