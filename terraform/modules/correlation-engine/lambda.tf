# ─── LAMBDA FUNCTIONS WITH CANARY DEPLOYMENT ─────────────────────────────────
# Uses Lambda aliases + weighted routing for zero-downtime canary deployments
# Traffic flow: Kinesis → alias (LIVE) → weighted split between versions

# ─── ENRICHMENT LAMBDA ────────────────────────────────────────────────────────
resource "aws_lambda_function" "enrichment" {
  function_name = "fault-correlation-enrichment-${var.environment}"
  role          = aws_iam_role.lambda_enrichment.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  architectures = ["arm64"]  # Graviton — 20% cheaper than x86
  memory_size   = var.lambda_memory_mb
  timeout       = 60
  publish       = true  # creates a new numbered version on every deploy

  filename         = "${path.module}/lambda/enrichment.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/enrichment.zip")

  environment {
    variables = {
      TOPOLOGY_TABLE  = aws_dynamodb_table.device_topology.name
      OUTPUT_STREAM   = aws_kinesis_stream.correlated_events.name
      AWS_REGION      = var.aws_region
      ENVIRONMENT     = var.environment
    }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active"  # X-Ray active tracing
  }

  tags = {
    Name        = "fault-correlation-enrichment-${var.environment}"
    Environment = var.environment
  }
}

# ─── ENRICHMENT LAMBDA ALIAS — LIVE ──────────────────────────────────────────
# Kinesis event source mapping points to this alias, not the function directly
# Allows canary traffic splitting without changing the event source mapping
resource "aws_lambda_alias" "enrichment_live" {
  name             = "LIVE"
  function_name    = aws_lambda_function.enrichment.function_name
  function_version = aws_lambda_function.enrichment.version

  # Canary routing — set via CI/CD pipeline, not Terraform
  # During normal operation: 100% to current version (no routing_config)
  # During canary: pipeline sets 10% weight to new version via AWS CLI

  lifecycle {
    ignore_changes = [routing_config]  # pipeline manages canary weights
  }

  tags = {
    Name        = "fault-correlation-enrichment-live-${var.environment}"
    Environment = var.environment
  }
}

# ─── KINESIS TRIGGER — POINTS TO ALIAS ───────────────────────────────────────
resource "aws_lambda_event_source_mapping" "kinesis_enrichment" {
  event_source_arn  = aws_kinesis_stream.raw_signals.arn
  function_name     = aws_lambda_alias.enrichment_live.arn  # alias not function
  starting_position = "LATEST"
  batch_size        = 100
  parallelization_factor = 3  # 3 concurrent Lambda invocations per shard

  bisect_batch_on_function_error = true  # isolates poison records to DLQ

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.enrichment_dlq.arn
    }
  }
}

# ─── ENRICHMENT DLQ ───────────────────────────────────────────────────────────
resource "aws_sqs_queue" "enrichment_dlq" {
  name                      = "fault-correlation-enrichment-dlq-${var.environment}"
  message_retention_seconds = 1209600  # 14 days

  tags = {
    Name        = "fault-correlation-enrichment-dlq-${var.environment}"
    Environment = var.environment
  }
}

# ─── ALERTING LAMBDA ──────────────────────────────────────────────────────────
resource "aws_lambda_function" "alerting" {
  function_name = "fault-correlation-alerting-${var.environment}"
  role          = aws_iam_role.lambda_alerting.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  architectures = ["arm64"]
  memory_size   = var.lambda_memory_mb
  timeout       = 30
  publish       = true

  filename         = "${path.module}/lambda/alerting.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/alerting.zip")

  environment {
    variables = {
      FAULT_STATUS_TABLE   = aws_dynamodb_table.fault_status.name
      SNS_DEVICE_FAULT_ARN = aws_sns_topic.device_fault.arn
      SNS_POP_FAULT_ARN    = aws_sns_topic.pop_fault.arn
      SNS_REGION_FAULT_ARN = aws_sns_topic.region_fault.arn
      AWS_REGION           = var.aws_region
      ENVIRONMENT          = var.environment
    }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active"
  }

  tags = {
    Name        = "fault-correlation-alerting-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_lambda_alias" "alerting_live" {
  name             = "LIVE"
  function_name    = aws_lambda_function.alerting.function_name
  function_version = aws_lambda_function.alerting.version

  lifecycle {
    ignore_changes = [routing_config]
  }
}

resource "aws_lambda_event_source_mapping" "kinesis_alerting" {
  event_source_arn = aws_kinesis_stream.correlated_events.arn
  function_name    = aws_lambda_alias.alerting_live.arn
  starting_position = "LATEST"
  batch_size        = 10

  bisect_batch_on_function_error = true

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.alerting_dlq.arn
    }
  }
}

resource "aws_sqs_queue" "alerting_dlq" {
  name                      = "fault-correlation-alerting-dlq-${var.environment}"
  message_retention_seconds = 1209600

  tags = {
    Name        = "fault-correlation-alerting-dlq-${var.environment}"
    Environment = var.environment
  }
}

# ─── SNS PERMISSION — ALLOW INVOKE ALERTING LAMBDA ───────────────────────────
resource "aws_lambda_permission" "sns_invoke_alerting" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alerting.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.region_fault.arn
}

# ─── CLOUDWATCH ALARMS — LAMBDA HEALTH ───────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "enrichment_error_rate" {
  alarm_name          = "fault-correlation-enrichment-errors-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Enrichment Lambda error rate > 5 — check canary deployment or DLQ"
  alarm_actions       = [aws_sns_topic.region_fault.arn]
  ok_actions          = [aws_sns_topic.region_fault.arn]

  dimensions = {
    FunctionName = aws_lambda_function.enrichment.function_name
    Resource     = "${aws_lambda_function.enrichment.function_name}:LIVE"
  }

  tags = {
    Name        = "fault-correlation-enrichment-errors-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "enrichment_duration" {
  alarm_name          = "fault-correlation-enrichment-duration-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 4000  # 4 seconds p99 — baseline is 200ms
  alarm_description   = "Enrichment Lambda p99 duration elevated — check X-Ray for slow subsegment"
  alarm_actions       = [aws_sns_topic.region_fault.arn]

  dimensions = {
    FunctionName = aws_lambda_function.enrichment.function_name
  }

  tags = {
    Name        = "fault-correlation-enrichment-duration-${var.environment}"
    Environment = var.environment
  }
}

# ─── CICD DORA METRICS — CUSTOM CLOUDWATCH NAMESPACE ─────────────────────────
resource "aws_cloudwatch_log_group" "cicd_metrics" {
  name              = "/cicd/fault-correlation-engine-${var.environment}"
  retention_in_days = 90

  tags = {
    Name        = "cicd-metrics-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_dashboard" "cicd_health" {
  dashboard_name = "fault-correlation-cicd-health-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0; y = 0; width = 12; height = 6
        properties = {
          title   = "Deployment Frequency (per day)"
          metrics = [["CICDMetrics", "DeploymentCount", "Environment", var.environment]]
          period  = 86400
          stat    = "Sum"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12; y = 0; width = 12; height = 6
        properties = {
          title   = "Change Failure Rate — Rollbacks"
          metrics = [
            ["CICDMetrics", "RollbackCount",    "Environment", var.environment],
            ["CICDMetrics", "DeploymentCount",  "Environment", var.environment]
          ]
          period = 86400
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0; y = 6; width = 12; height = 6
        properties = {
          title   = "Lambda Error Rate — Enrichment"
          metrics = [["AWS/Lambda", "Errors", "FunctionName", "fault-correlation-enrichment-${var.environment}"]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12; y = 6; width = 12; height = 6
        properties = {
          title   = "DLQ Depth — Failed Records"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "fault-correlation-enrichment-dlq-${var.environment}"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "fault-correlation-alerting-dlq-${var.environment}"]
          ]
          period = 300
          stat   = "Maximum"
          view   = "timeSeries"
        }
      }
    ]
  })
}
