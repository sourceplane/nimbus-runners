# Webhook redelivery sweeper (redelivery/index.mjs). GitHub never retries a
# failed webhook delivery, so a throttled or unavailable webhook lambda leaves
# the job it announced queued forever. Every minute this re-requests failed
# `workflow_job: queued` deliveries for the allowed repositories.

locals {
  redelivery_name = "${local.prefix}-webhook-redelivery"
}

data "archive_file" "redelivery" {
  type        = "zip"
  source_file = "${path.module}/redelivery/index.mjs"
  output_path = "${path.module}/.build/redelivery.zip"
}

# Per-job redelivery counts (the function owns the value).
resource "aws_ssm_parameter" "redelivery_state" {
  name        = "/${local.ssm_root}/redelivery/state"
  description = "Webhook redelivery sweeper state: last redelivery per job id"
  type        = "String"
  value       = "{}"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_cloudwatch_log_group" "redelivery" {
  name              = "/aws/lambda/${local.redelivery_name}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "redelivery_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redelivery" {
  name                 = local.redelivery_name
  path                 = local.iam_path
  permissions_boundary = local.role_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.redelivery_assume.json
}

data "aws_iam_policy_document" "redelivery" {
  statement {
    sid       = "AppCredentials"
    actions   = ["ssm:GetParameter"]
    resources = [local.ssm_arn_for["id"], local.ssm_arn_for["key_base64"]]
  }
  statement {
    sid       = "State"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.redelivery_state.arn]
  }
  statement {
    sid       = "DecryptSecureString"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.aws_region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.redelivery.arn}:*"]
  }
}

resource "aws_iam_role_policy" "redelivery" {
  name   = local.redelivery_name
  role   = aws_iam_role.redelivery.id
  policy = data.aws_iam_policy_document.redelivery.json
}

resource "aws_lambda_function" "redelivery" {
  function_name    = local.redelivery_name
  role             = aws_iam_role.redelivery.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.redelivery.output_path
  source_code_hash = data.archive_file.redelivery.output_base64sha256
  memory_size      = 128
  timeout          = 60

  environment {
    variables = {
      APP_ID_PARAM         = "${local.github_app_ssm_prefix}/id"
      APP_KEY_PARAM        = "${local.github_app_ssm_prefix}/key_base64"
      ALLOWED_REPOSITORIES = join(",", local.allowed_repositories)
      STATE_PARAM          = aws_ssm_parameter.redelivery_state.name
      WINDOW_MINUTES       = "60"
      MAX_ATTEMPTS         = "3"
      BACKOFF_MINUTES      = "4"
      SPACING_MS           = "300"
    }
  }

  depends_on = [aws_cloudwatch_log_group.redelivery, aws_iam_role_policy.redelivery]
}

resource "aws_cloudwatch_event_rule" "redelivery" {
  name                = local.redelivery_name
  description         = "Re-request failed workflow_job deliveries to the nimbus-runners webhook"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "redelivery" {
  rule = aws_cloudwatch_event_rule.redelivery.name
  arn  = aws_lambda_function.redelivery.arn
}

resource "aws_lambda_permission" "redelivery" {
  statement_id  = "events-schedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.redelivery.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.redelivery.arn
}
