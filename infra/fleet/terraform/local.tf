locals {
  aws_region  = coalesce(var.awsRegion, "us-east-1")
  environment = coalesce(var.environment, "prod")
  component   = coalesce(var.component, "fleet")
  namespace   = coalesce(var.namespace, "sourceplane")
  owner       = coalesce(var.owner, "sourceplane")
  repo        = coalesce(var.repo, "nimbus-runners")

  # ---------------------------------------------------------------------------
  # The fleet. Every name the module creates starts with the prefix, and the
  # aws-admin role github-sourceplane-nimbus-runners is scoped to it.
  # ---------------------------------------------------------------------------
  prefix = "nimbus-runners"

  # github-aws-runners/terraform-aws-github-runner release. The lambda zips are
  # pinned to the same tag as the module (lambdas.tf).
  runner_module_version = "7.11.0"

  # Repositories allowed to start runners. This repository is public and never
  # listed (NR-G); everything not listed is ignored by the webhook.
  allowed_repositories = [
    "sourceplane/orun-cloud",
    "sourceplane/orun-managed-runners",
  ]

  # Jobs select the fleet with: runs-on: [self-hosted, linux, x64, nimbus]
  runner_labels = ["nimbus"]

  # orun-cloud peaks at ~120 concurrent lanes on a full verify; 100 is the
  # budgeted burst. Lanes above the cap wait in the queue, they are not dropped.
  runners_maximum_count = 100

  # 2 vCPU / 8 GiB x86_64, the GitHub-hosted ubuntu-latest (private repo) shape.
  # Many types across 5 AZs gives price-capacity-optimized deep spot pools for
  # a 100-instance burst. No T-family: CI exhausts burst credits and unlimited
  # mode bills a surcharge.
  instance_types = [
    "m7i-flex.large",
    "m6a.large",
    "m5a.large",
    "m6i.large",
    "m5.large",
    "m7i.large",
    "m7a.large",
  ]

  root_volume_gb = 40

  # IAM: every role and instance profile under this path, every role carrying
  # the aws-admin-owned boundary (the deploy role cannot create one without it).
  iam_path          = "/${local.prefix}/"
  role_boundary_arn = "arn:aws:iam::${local.account_id}:policy/${local.prefix}-boundary"

  # SSM: everything under /nimbus-runners/.
  ssm_root = local.prefix

  # The prebuilt AMI id lives in this parameter. Terraform creates it with a
  # placeholder and ignores its value; the runner-ami workflow writes each new
  # image id (image/ and .github/workflows/runner-ami.yaml).
  ami_ssm_parameter_name = "/${local.ssm_root}/ami-id"

  # GitHub App credentials, written out of band (BOOTSTRAP.md) so no secret
  # passes through Terraform state or CI.
  github_app_ssm_prefix = "/${local.ssm_root}/github-app"

  # Monthly cost guardrail for the services the fleet bills to.
  monthly_budget_usd  = 55
  budget_alert_emails = []

  vpc_cidr = "10.80.0.0/16"
  # us-east-1e is skipped: it lacks most current-generation instance types.
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]

  common_tags = {
    ManagedBy   = "orun"
    Environment = local.environment
    Namespace   = local.namespace
    Owner       = local.owner
    Repo        = local.repo
    Component   = local.component
    Fleet       = local.prefix
  }
}
