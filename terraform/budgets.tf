# AWS Budget alerts — guards against runaway GPU spend during testing.
#
# Costs to expect in dev:
#   Idle (no GPU nodes):   ~$4-5/day  ($0.17-0.21/hr)
#   Under test load:       ~$8-12/day ($0.33-0.50/hr, g4dn.xlarge spot + EC2 time)
#   Accidentally left on:  up to $18+/day if GPU nodes don't consolidate
#
# The daily budget is set to $20 — safe for testing, warns at $16 (80%).

resource "aws_budgets_budget" "daily" {
  name         = "${var.cluster_name}-daily"
  budget_type  = "COST"
  limit_amount = var.budget_daily_limit_usd
  limit_unit   = "USD"
  time_unit    = "DAILY"

  # No cost_filter — tracks all account spend.
  # To scope to this cluster only, activate the "Name" Cost Allocation Tag in
  # AWS Billing console and add:
  #   cost_filter { name = "TagKeyValue"; values = ["user:Name$<cluster-name>"] }

  # Alert at 80% of daily limit (actual spend only — FORECASTED is not supported on DAILY budgets)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(tonumber(var.budget_daily_limit_usd) * 30)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # Forecast alert is supported on MONTHLY budgets
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
