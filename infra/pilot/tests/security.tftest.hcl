mock_provider "aws" {}

variables {
  account_id = "123456789012"
  region     = "us-east-2"
  mount_source_roles = {
    mac     = "arn:aws:iam::123456789012:role/test-mac"
    windows = "arn:aws:iam::123456789012:role/test-windows"
  }
}

override_resource {
  target = aws_s3_bucket.blocks
  values = {
    arn                         = "arn:aws:s3:::project-drive-123456789012-us-east-2"
    bucket_regional_domain_name = "project-drive-123456789012-us-east-2.s3.us-east-2.amazonaws.com"
  }
}

run "bucket_and_mount_role_boundaries" {
  command = apply

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.blocks.block_public_acls,
      aws_s3_bucket_public_access_block.blocks.ignore_public_acls,
      aws_s3_bucket_public_access_block.blocks.block_public_policy,
      aws_s3_bucket_public_access_block.blocks.restrict_public_buckets,
      one(aws_s3_bucket_ownership_controls.blocks.rule).object_ownership == "BucketOwnerEnforced",
      one(one(aws_s3_bucket_server_side_encryption_configuration.blocks.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256",
      !aws_s3_bucket.blocks.force_destroy,
    ])
    error_message = "Keep the block bucket private, encrypted, and protected from forced destruction."
  }

  assert {
    condition = (
      jsondecode(aws_s3_bucket_policy.transport.policy).Statement[0].Effect == "Deny" &&
      jsondecode(aws_s3_bucket_policy.transport.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    )
    error_message = "The bucket must deny cleartext access."
  }

  assert {
    condition = alltrue([
      for device in keys(var.mount_source_roles) :
      jsondecode(aws_iam_role.mount[device].assume_role_policy).Statement[0].Principal.AWS == var.mount_source_roles[device] &&
      aws_iam_role.mount[device].max_session_duration == 3600 &&
      jsondecode(aws_iam_role_policy.mount[device].policy).Statement[2].Resource == "${aws_s3_bucket.blocks.arn}/project-drive/*" &&
      length(jsondecode(aws_iam_role_policy.mount[device].policy).Statement) == 3
    ])
    error_message = "Each device must have an isolated role with object access scoped to the volume prefix."
  }
}

run "shared_source_role_is_rejected" {
  command = plan

  variables {
    mount_source_roles = {
      mac     = "arn:aws:iam::123456789012:role/shared"
      windows = "arn:aws:iam::123456789012:role/shared"
    }
  }

  expect_failures = [var.mount_source_roles]
}

run "mac_only_creates_no_windows_role" {
  command = plan

  variables {
    mount_source_roles = {
      mac = "arn:aws:iam::123456789012:role/test-mac"
    }
  }

  assert {
    condition = (
      toset(keys(aws_iam_role.mount)) == toset(["mac"]) &&
      toset(keys(aws_iam_role_policy.mount)) == toset(["mac"])
    )
    error_message = "The Mac-only configuration must omit the Windows mount role and policy."
  }
}

run "mac_role_is_required" {
  command = plan

  variables {
    mount_source_roles = {
      mac     = null
      windows = "arn:aws:iam::123456789012:role/test-windows"
    }
  }

  expect_failures = [var.mount_source_roles]
}
