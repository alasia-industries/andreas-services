# ─── Account cost guardrails ─────────────────────────────────────────────────
#
# Account-wide, so shared. One SNS topic carries both the budget and the
# anomaly alerts: Cost Anomaly Detection only accepts an SNS subscriber for
# IMMEDIATE alerts (email subscribers are DAILY/WEEKLY only), and the budget
# reuses it so there is one subscription to confirm, not two.
#
# The email subscription is created only when `alert_email` is set
# (TF_VAR_alert_email from the `ALERT_EMAIL` secret). SNS then mails a
# confirmation link; nothing is delivered until it is clicked.

data "aws_caller_identity" "current" {}

locals {
  cost_alerts_name = "platform-shared-cost-alerts"
}

resource "aws_sns_topic" "cost_alerts" {
  name = local.cost_alerts_name
  tags = local.shared_tags
}

data "aws_iam_policy_document" "cost_alerts_topic" {
  statement {
    sid       = "BudgetsAndCostAnomalyPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.cost_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }

    # Confused-deputy guard: only this account's budgets and monitors.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "cost_alerts" {
  arn    = aws_sns_topic.cost_alerts.arn
  policy = data.aws_iam_policy_document.cost_alerts_topic.json
}

resource "aws_sns_topic_subscription" "cost_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Monthly cost budget for the whole account. 50/80/100% of actual spend, and
# 100% of forecast so a runaway is caught before the month closes.
resource "aws_budgets_budget" "monthly_cost" {
  name         = "platform-shared-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
    }
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
  }

  tags = local.shared_tags

  # The topic policy must exist before Budgets validates the subscriber, and
  # the CI role needs its budgets:* grant before the create call.
  depends_on = [aws_sns_topic_policy.cost_alerts, aws_iam_role_policy_attachment.github_actions]
}

# Per-service anomaly detection. An account may hold only one DIMENSIONAL
# SERVICE monitor; none existed when this was written.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "platform-shared-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  tags              = local.shared_tags

  depends_on = [aws_iam_role_policy_attachment.github_actions]
}

resource "aws_ce_anomaly_subscription" "services" {
  name             = "platform-shared-cost-anomalies"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  tags = local.shared_tags

  depends_on = [aws_sns_topic_policy.cost_alerts]
}
