# ─── NETWORK FIREWALL ────────────────────────────────────────────────────────
# Optional module — enable when Lambda needs to call external APIs (e.g. ServiceNow)
# Cost: ~$0.395/hr per AZ + $0.065/GB processed
# Set var.enable_network_firewall = true to activate

# ─── FIREWALL SUBNET ─────────────────────────────────────────────────────────
resource "aws_subnet" "firewall_a" {
  count             = var.enable_network_firewall ? 1 : 0
  vpc_id            = aws_vpc.correlation_engine.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 4)
  availability_zone = "${var.aws_region}a"

  tags = {
    Name        = "fault-correlation-firewall-a-${var.environment}"
    Environment = var.environment
    Tier        = "firewall"
  }
}

# ─── FIREWALL RULE GROUP — DOMAIN ALLOWLIST ──────────────────────────────────
resource "aws_networkfirewall_rule_group" "egress_allowlist" {
  count    = var.enable_network_firewall ? 1 : 0
  name     = "fault-correlation-egress-allowlist-${var.environment}"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]

        # Add allowed domains here — e.g. ServiceNow, PagerDuty, Datadog
        targets = var.allowed_egress_domains
      }
    }
  }

  tags = {
    Name        = "fault-correlation-egress-allowlist-${var.environment}"
    Environment = var.environment
  }
}

# ─── FIREWALL POLICY ─────────────────────────────────────────────────────────
resource "aws_networkfirewall_firewall_policy" "correlation_engine" {
  count = var.enable_network_firewall ? 1 : 0
  name  = "fault-correlation-firewall-policy-${var.environment}"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.egress_allowlist[0].arn
    }
  }

  tags = {
    Name        = "fault-correlation-firewall-policy-${var.environment}"
    Environment = var.environment
  }
}

# ─── FIREWALL ─────────────────────────────────────────────────────────────────
resource "aws_networkfirewall_firewall" "correlation_engine" {
  count               = var.enable_network_firewall ? 1 : 0
  name                = "fault-correlation-firewall-${var.environment}"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.correlation_engine[0].arn
  vpc_id              = aws_vpc.correlation_engine.id

  subnet_mapping {
    subnet_id = aws_subnet.firewall_a[0].id
  }

  tags = {
    Name        = "fault-correlation-firewall-${var.environment}"
    Environment = var.environment
  }
}

# ─── FIREWALL LOGGING ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "firewall_alerts" {
  count             = var.enable_network_firewall ? 1 : 0
  name              = "/aws/network-firewall/alerts-${var.environment}"
  retention_in_days = 30

  tags = {
    Name        = "fault-correlation-firewall-alerts-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "firewall_flows" {
  count             = var.enable_network_firewall ? 1 : 0
  name              = "/aws/network-firewall/flows-${var.environment}"
  retention_in_days = 7

  tags = {
    Name        = "fault-correlation-firewall-flows-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_networkfirewall_logging_configuration" "correlation_engine" {
  count        = var.enable_network_firewall ? 1 : 0
  firewall_arn = aws_networkfirewall_firewall.correlation_engine[0].arn

  logging_configuration {
    # Alert log — blocked connections
    log_destination_config {
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_alerts[0].name
      }
    }

    # Flow log — all connections (allowed and blocked)
    log_destination_config {
      log_destination_type = "CloudWatchLogs"
      log_type             = "FLOW"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_flows[0].name
      }
    }
  }
}

# ─── ROUTE TABLES WITH FIREWALL ──────────────────────────────────────────────
# When firewall is enabled, traffic flows:
# Private → NAT → Firewall → IGW → Internet
# Return: IGW → Firewall → NAT → Private

locals {
  # Extract firewall endpoint ID from firewall sync states
  firewall_endpoint_id = var.enable_network_firewall ? tolist(
    tolist(aws_networkfirewall_firewall.correlation_engine[0].firewall_status[0].sync_states)[0].attachment
  )[0].endpoint_id : null
}

# Public subnet route — NAT Gateway sends to Firewall (when enabled)
resource "aws_route" "public_to_firewall" {
  count                  = var.enable_network_firewall ? 1 : 0
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoint_id

  depends_on = [aws_networkfirewall_firewall.correlation_engine]
}

# Firewall subnet route table
resource "aws_route_table" "firewall" {
  count  = var.enable_network_firewall ? 1 : 0
  vpc_id = aws_vpc.correlation_engine.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.correlation_engine.id
  }

  tags = {
    Name        = "fault-correlation-firewall-rt-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "firewall_a" {
  count          = var.enable_network_firewall ? 1 : 0
  subnet_id      = aws_subnet.firewall_a[0].id
  route_table_id = aws_route_table.firewall[0].id
}

# ─── CLOUDWATCH ALARM — BLOCKED EGRESS ───────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "firewall_blocked_egress" {
  count               = var.enable_network_firewall ? 1 : 0
  alarm_name          = "fault-correlation-firewall-blocked-egress-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DroppedPackets"
  namespace           = "AWS/NetworkFirewall"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Network Firewall blocking egress traffic — check /aws/network-firewall/alerts for domain details"
  alarm_actions       = [aws_sns_topic.region_fault.arn]

  dimensions = {
    FirewallName = "fault-correlation-firewall-${var.environment}"
    AvailabilityZone = "${var.aws_region}a"
  }

  tags = {
    Name        = "fault-correlation-firewall-blocked-egress-${var.environment}"
    Environment = var.environment
  }
}
