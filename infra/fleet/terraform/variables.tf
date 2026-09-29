# stack-granite's terraform-aws composition exports every component parameter
# as TF_VAR_<name>, plus TF_VAR_environment and TF_VAR_component. Only the ones
# this root reads are declared; the rest are ignored by Terraform.

variable "awsRegion" {
  type    = string
  default = null
}

variable "environment" {
  type    = string
  default = null
}

variable "component" {
  type    = string
  default = null
}

variable "namespace" {
  type    = string
  default = null
}

variable "owner" {
  type    = string
  default = null
}

variable "repo" {
  type    = string
  default = null
}
