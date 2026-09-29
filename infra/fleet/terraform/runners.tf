# Ephemeral spot runners: one job per instance, JIT-registered, terminated by
# the start script as soon as the job ends. Boot speed and cost come from the
# prebuilt AMI (runner, docker, node 20/22, pnpm and the Playwright system
# deps baked in; no user-data install and no binaries syncer).

# Placeholder so the launch template resolves before the first image exists.
data "aws_ssm_parameter" "ubuntu_noble" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_ssm_parameter" "runner_ami_id" {
  name        = local.ami_ssm_parameter_name
  description = "Prebuilt GitHub runner AMI id, written by the runner-ami workflow"
  type        = "String"
  data_type   = "text"
  value       = data.aws_ssm_parameter.ubuntu_noble.insecure_value

  lifecycle {
    ignore_changes = [value]
  }
}

module "runners" {
  source  = "github-aws-runners/github-runner/aws"
  version = "7.11.0"

  aws_region = local.aws_region
  prefix     = local.prefix
  tags       = local.common_tags

  # IAM and SSM inside the names the aws-admin role is scoped to.
  role_path                 = local.iam_path
  instance_profile_path     = local.iam_path
  role_permissions_boundary = local.role_boundary_arn
  ssm_paths = {
    root       = local.ssm_root
    use_prefix = false
  }

  vpc_id                        = aws_vpc.runners.id
  subnet_ids                    = [for s in aws_subnet.public : s.id]
  associate_public_ipv4_address = true

  github_app = {
    id_ssm             = { name = "${local.github_app_ssm_prefix}/id", arn = local.ssm_arn_for["id"] }
    key_base64_ssm     = { name = "${local.github_app_ssm_prefix}/key_base64", arn = local.ssm_arn_for["key_base64"] }
    webhook_secret_ssm = { name = "${local.github_app_ssm_prefix}/webhook_secret", arn = local.ssm_arn_for["webhook_secret"] }
  }

  # Lambdas from the pinned release, via S3 (lambdas.tf).
  lambda_s3_bucket      = aws_s3_bucket.lambdas.id
  webhook_lambda_s3_key = aws_s3_object.lambda_zip["webhook"].key
  runners_lambda_s3_key = aws_s3_object.lambda_zip["runners"].key
  lambda_architecture   = "arm64"
  eventbridge           = { enable = false }

  # Org-level registration, filtered to the budgeted repositories.
  enable_organization_runners = true
  repository_white_list       = local.allowed_repositories
  runner_extra_labels         = local.runner_labels
  runner_name_prefix          = "nimbus-"

  # One job per instance, JIT config, no reuse between jobs.
  enable_ephemeral_runners = true
  enable_jit_config        = true
  # Superseded PR runs are cancelled by orun-cloud's concurrency group; the
  # short delay plus the queued check means a cancelled lane never boots.
  delay_webhook_event     = 10
  enable_job_queued_check = true
  job_retry = {
    enable           = true
    delay_in_seconds = 120
    max_attempts     = 1
  }

  # Burst: ~120 lanes land within seconds on a full verify.
  runners_maximum_count                                          = local.runners_maximum_count
  scale_up_reserved_concurrent_executions                        = 5
  lambda_event_source_mapping_batch_size                         = 20
  lambda_event_source_mapping_maximum_batching_window_in_seconds = 1
  minimum_running_time_in_minutes                                = 3
  runner_boot_time_in_minutes                                    = 4

  # Spot, cheapest-deepest pools first, on-demand only when spot has no capacity.
  instance_target_capacity_type               = "spot"
  instance_allocation_strategy                = "price-capacity-optimized"
  instance_types                              = local.instance_types
  enable_runner_on_demand_failover_for_errors = ["InsufficientInstanceCapacity"]
  create_service_linked_role_spot             = true
  instance_termination_watcher = {
    enable = true
    s3_key = aws_s3_object.lambda_zip["termination-watcher"].key
  }

  # Prebuilt image (image/): no user data, no binaries syncer.
  runner_os                     = "linux"
  runner_architecture           = "x64"
  enable_userdata               = false
  enable_runner_binaries_syncer = false
  # Built from known values: the module counts resources on this ARN, so it
  # must be known at plan time (the parameter's own .arn is not, on first apply).
  ami = {
    id_ssm_parameter_arn = "arn:aws:ssm:${local.aws_region}:${local.account_id}:parameter${aws_ssm_parameter.runner_ami_id.name}"
  }
  # Consumers (orun-cloud) hard-code /home/runner (DOCKER_CONFIG, the shared caches).
  runner_run_as = "runner"

  block_device_mappings = [{
    device_name = "/dev/sda1"
    volume_size = local.root_volume_gb
    volume_type = "gp3"
    iops        = 3000
    throughput  = 250
  }]

  # Debug access without ingress rules or SSH keys.
  enable_ssm_on_runners = true

  # Cost: no runner-side CloudWatch agent, short lambda log retention.
  enable_cloudwatch_agent   = false
  logging_retention_in_days = 7
}
