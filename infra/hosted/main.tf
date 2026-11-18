terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Enter the pilot project's 12-digit AWS account ID."
  }
}

variable "region" {
  type = string
  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.region))
    error_message = "Use the Region assigned to the pilot project."
  }
}

variable "availability_zone" {
  type = string
  validation {
    condition     = can(regex("^${var.region}[a-z]$", var.availability_zone))
    error_message = "Choose a Lightsail availability zone in the assigned Region."
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "ProjectDrive"
      Environment = "pilot"
      ManagedBy   = "Terraform"
    }
  }
}

locals {
  bootstrap_files = toset(["hosted-index.sh", "index-pg_hba.conf", "index-roles.sql"])
}

resource "aws_lightsail_instance" "index" {
  name              = "project-drive-index"
  availability_zone = var.availability_zone
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = "micro_3_0"
  ip_address_type   = "ipv4"
  user_data         = <<-BOOT
    #!/bin/bash
    set -eu
    umask 022
    install -d -m 0755 /opt/project-drive
    %{for filename in local.bootstrap_files~}
    printf '%s' '${filebase64("${path.module}/../../scripts/${filename}")}' | base64 -d > '/opt/project-drive/${filename}'
    %{endfor~}
  BOOT

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_lightsail_instance_public_ports" "browser_ssh" {
  instance_name = aws_lightsail_instance.index.name

  port_info {
    protocol          = "tcp"
    from_port         = 22
    to_port           = 22
    cidr_list_aliases = ["lightsail-connect"]
  }
}

resource "aws_lightsail_disk" "postgres" {
  name              = "project-drive-index-data"
  size_in_gb        = 8
  availability_zone = aws_lightsail_instance.index.availability_zone

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_lightsail_disk_attachment" "postgres" {
  disk_name     = aws_lightsail_disk.postgres.name
  instance_name = aws_lightsail_instance.index.name
  disk_path     = "/dev/xvdf"
}

output "instance_name" {
  value = aws_lightsail_instance.index.name
}

output "database_disk" {
  value = aws_lightsail_disk.postgres.name
}
