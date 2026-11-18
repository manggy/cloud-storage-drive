terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
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

variable "region" {
  description = "The Region assigned in AWS Settings."
  type        = string
  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.region))
    error_message = "Enter a commercial AWS Region such as us-east-2."
  }
}

variable "account_id" {
  description = "The 12-digit AWS account ID for the pilot project."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Enter the pilot project's 12-digit AWS account ID."
  }
}

variable "mount_source_roles" {
  description = "Existing unprivileged federated IAM roles. Omit windows for the Mac-only setup."
  type = object({
    mac     = string
    windows = optional(string)
  })
  nullable = false

  validation {
    condition = (
      var.mount_source_roles.mac != null &&
      var.mount_source_roles.mac != var.mount_source_roles.windows &&
      alltrue([
        for arn in values(var.mount_source_roles) :
        can(regex("^arn:aws:iam::${var.account_id}:role/[A-Za-z0-9_+=,.@/-]+$", arn))
        if arn != null
      ])
    )
    error_message = "Use a Mac role ARN in this AWS account and a distinct Windows ARN if applicable."
  }
}

locals {
  volume_name = "project-drive"
  bucket_name = "${local.volume_name}-${var.account_id}-${var.region}"
  mount_roles = { for device, arn in var.mount_source_roles : device => arn if arn != null }
}

resource "aws_s3_bucket" "blocks" {
  bucket        = local.bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "blocks" {
  bucket                  = aws_s3_bucket.blocks.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "blocks" {
  bucket = aws_s3_bucket.blocks.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "blocks" {
  bucket = aws_s3_bucket.blocks.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "transport" {
  bucket     = aws_s3_bucket.blocks.id
  depends_on = [aws_s3_bucket_public_access_block.blocks]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyCleartext"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.blocks.arn, "${aws_s3_bucket.blocks.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "blocks" {
  bucket = aws_s3_bucket.blocks.id

  rule {
    id     = "abort-abandoned-multipart-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_role" "mount" {
  for_each             = local.mount_roles
  name                 = "project-drive-${each.key}-mount"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = each.value }
    }]
  })
}

resource "aws_iam_role_policy" "mount" {
  for_each = aws_iam_role.mount
  name     = "project-drive-blocks"
  role     = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketRegionAndMultipart"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.blocks.arn
      },
      {
        Sid      = "ListVolume"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.blocks.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.volume_name}/", "${local.volume_name}/*"] }
        }
      },
      {
        Sid    = "VolumeObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.blocks.arn}/${local.volume_name}/*"
      },
    ]
  })
}

output "bucket_endpoint" {
  value = "https://${aws_s3_bucket.blocks.bucket_regional_domain_name}"
}

output "mount_roles" {
  value = { for device, role in aws_iam_role.mount : device => role.arn }
}
