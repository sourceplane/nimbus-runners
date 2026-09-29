# Monthly guardrail over the services the runner fleet bills to. Not tag
# scoped (tag filters need a cost-allocation tag activated in Billing, and the
# public IPv4 charge cannot be tagged), so anything else in this account that
# uses these services counts too; today that is only this fleet.
resource "aws_budgets_budget" "runners" {
  name         = "${local.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(local.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "Service"
    values = [
      "Amazon Elastic Compute Cloud - Compute",
      "EC2 - Other",
      "Amazon Virtual Private Cloud",
      "AWS Lambda",
      "Amazon API Gateway",
      "Amazon Simple Queue Service",
      "AmazonCloudWatch",
    ]
  }

  dynamic "notification" {
    for_each = length(local.budget_alert_emails) > 0 ? {
      actual_80      = { threshold = 80, type = "ACTUAL" }
      forecasted_100 = { threshold = 100, type = "FORECASTED" }
    } : {}

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = local.budget_alert_emails
    }
  }
}
