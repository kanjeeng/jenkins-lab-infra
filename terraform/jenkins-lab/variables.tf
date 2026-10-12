variable "aws_region" {
  description = "Region AWS"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix nama resource"
  type        = string
  default     = "jenkins-lab"
}

variable "vpc_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.2.1.0/24"
}

variable "jenkins_private_ip" {
  type    = string
  default = "10.2.1.10"
}

variable "app_private_ip" {
  type    = string
  default = "10.2.1.20"
}

variable "jenkins_instance_type" {
  description = "t3.small (2 GB) cukup dengan swap. Naikkan ke t3.medium bila build Next.js sering kehabisan memori."
  type        = string
  default     = "t3.small"
}

variable "app_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "jenkins_volume_size" {
  type    = number
  default = 30
}

variable "app_volume_size" {
  type    = number
  default = 20
}

variable "swap_size_gb" {
  type    = number
  default = 2
}

variable "admin_public_key_path" {
  description = "Kunci publik admin (laptop ke Server 1 dan Server 2)"
  type        = string
  default     = "~/.ssh/jenkins_lab_admin.pub"
}

variable "deploy_public_key_path" {
  description = "Kunci publik deploy (Jenkins ke Server 2). Dipasang oleh User Data Server 2."
  type        = string
  default     = "~/.ssh/jenkins_lab_deploy.pub"
}

variable "developer_ip_cidr" {
  description = "IP publik pengembang dalam format /32 untuk SSH dan UI Jenkins"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.developer_ip_cidr)) && endswith(var.developer_ip_cidr, "/32") && var.developer_ip_cidr != "0.0.0.0/0"
    error_message = "developer_ip_cidr harus berupa satu alamat IP dengan akhiran /32 dan tidak boleh 0.0.0.0/0."
  }
}
