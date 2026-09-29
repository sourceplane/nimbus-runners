# The module's lambdas are published as release assets. They are fetched at
# plan time and stored in S3, so the root needs no pre-download step and a
# fresh CI runner plans the same as a laptop. Each zip is < 1 MB.

locals {
  lambda_zips = toset([
    "webhook",
    "runners",
    "termination-watcher",
  ])
}

data "http" "lambda_zip" {
  for_each = local.lambda_zips

  url = "https://github.com/github-aws-runners/terraform-aws-github-runner/releases/download/v${local.runner_module_version}/${each.key}.zip"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Failed to download ${each.key}.zip for v${local.runner_module_version}."
    }
  }
}

resource "aws_s3_bucket" "lambdas" {
  bucket_prefix = "${local.prefix}-lambdas-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lambdas" {
  bucket = aws_s3_bucket.lambdas.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lambdas" {
  bucket = aws_s3_bucket.lambdas.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "lambda_zip" {
  for_each = local.lambda_zips

  bucket         = aws_s3_bucket.lambdas.id
  key            = "v${local.runner_module_version}/${each.key}.zip"
  content_base64 = data.http.lambda_zip[each.key].response_body_base64
  content_type   = "application/zip"
}
