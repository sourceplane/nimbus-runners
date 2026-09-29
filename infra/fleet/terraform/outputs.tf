output "webhook_endpoint" {
  description = "Webhook URL to set on the GitHub App"
  value       = module.runners.webhook.endpoint
}

output "runner_labels" {
  description = "runs-on labels that select this fleet"
  value       = concat(["self-hosted", "linux", "x64"], local.runner_labels)
}

output "ami_ssm_parameter_name" {
  description = "SSM parameter the runner-ami workflow writes the AMI id to"
  value       = aws_ssm_parameter.runner_ami_id.name
}

output "vpc_id" {
  value = aws_vpc.runners.id
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "runner_role_name" {
  value = module.runners.runners.role_runner.name
}
