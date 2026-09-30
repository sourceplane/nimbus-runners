terraform {
  required_version = ">= 1.15.3"

  # State lives on the Orun platform: the runner exports TF_HTTP_* per job
  # (stack-granite terraform-aws), so this needs no -backend-config and no
  # bucket to bootstrap.
  backend "http" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.33"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = local.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  ssm_arn_for = { for k in ["id", "key_base64", "webhook_secret"] : k => "arn:aws:ssm:${local.aws_region}:${local.account_id}:parameter${local.github_app_ssm_prefix}/${k}" }
}
