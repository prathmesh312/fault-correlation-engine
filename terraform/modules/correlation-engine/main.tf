# ─── VPC ────────────────────────────────────────────────────────────────────
resource "aws_vpc" "correlation_engine" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "fault-correlation-vpc-${var.environment}"
    Environment = var.environment
    System      = "fault-correlation-engine"
  }
}

# ─── SUBNETS ─────────────────────────────────────────────────────────────────
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.correlation_engine.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone = "${var.aws_region}a"

  tags = {
    Name        = "fault-correlation-private-a-${var.environment}"
    Environment = var.environment
    Tier        = "private"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.correlation_engine.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 1)
  availability_zone = "${var.aws_region}b"

  tags = {
    Name        = "fault-correlation-private-b-${var.environment}"
    Environment = var.environment
    Tier        = "private"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.correlation_engine.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 2)
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "fault-correlation-public-a-${var.environment}"
    Environment = var.environment
    Tier        = "public"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.correlation_engine.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 3)
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name        = "fault-correlation-public-b-${var.environment}"
    Environment = var.environment
    Tier        = "public"
  }
}

# ─── INTERNET GATEWAY ────────────────────────────────────────────────────────
resource "aws_internet_gateway" "correlation_engine" {
  vpc_id = aws_vpc.correlation_engine.id

  tags = {
    Name        = "fault-correlation-igw-${var.environment}"
    Environment = var.environment
  }
}

# ─── NAT GATEWAY ─────────────────────────────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name        = "fault-correlation-nat-eip-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "correlation_engine" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  depends_on    = [aws_internet_gateway.correlation_engine]

  tags = {
    Name        = "fault-correlation-nat-${var.environment}"
    Environment = var.environment
  }
}

# ─── ROUTE TABLES ────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.correlation_engine.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.correlation_engine.id
  }

  tags = {
    Name        = "fault-correlation-public-rt-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.correlation_engine.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.correlation_engine.id
  }

  tags = {
    Name        = "fault-correlation-private-rt-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# ─── VPC ENDPOINTS ───────────────────────────────────────────────────────────
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.correlation_engine.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name        = "fault-correlation-dynamodb-endpoint-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.correlation_engine.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name        = "fault-correlation-s3-endpoint-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "fault-correlation-vpc-endpoints-sg-${var.environment}"
  description = "Allow HTTPS from private subnets to VPC endpoints"
  vpc_id      = aws_vpc.correlation_engine.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.private_a.cidr_block, aws_subnet.private_b.cidr_block]
    description = "HTTPS from private subnets"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name        = "fault-correlation-vpc-endpoints-sg-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_vpc_endpoint" "kinesis" {
  vpc_id              = aws_vpc.correlation_engine.id
  service_name        = "com.amazonaws.${var.aws_region}.kinesis-streams"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name        = "fault-correlation-kinesis-endpoint-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.correlation_engine.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name        = "fault-correlation-cwlogs-endpoint-${var.environment}"
    Environment = var.environment
  }
}

# ─── KMS KEYS ─────────────────────────────────────────────────────────────────
resource "aws_kms_key" "kinesis" {
  description             = "KMS key for Kinesis streams - ${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name        = "fault-correlation-kinesis-key-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "kinesis" {
  name          = "alias/fault-correlation-kinesis-${var.environment}"
  target_key_id = aws_kms_key.kinesis.key_id
}

resource "aws_kms_key" "dynamodb" {
  description             = "KMS key for DynamoDB tables - ${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name        = "fault-correlation-dynamodb-key-${var.environment}"
    Environment = var.environment
  }
}

# ─── KINESIS STREAMS ─────────────────────────────────────────────────────────
resource "aws_kinesis_stream" "raw_signals" {
  name             = "network-fault-raw-signals-${var.environment}"
  shard_count      = var.shard_count
  retention_period = var.retention_period_hours

  encryption_type = "KMS"
  kms_key_id      = aws_kms_key.kinesis.arn

  tags = {
    Name        = "network-fault-raw-signals-${var.environment}"
    Environment = var.environment
    Stream      = "stream-1-raw"
  }
}

resource "aws_kinesis_stream" "correlated_events" {
  name             = "network-fault-correlated-events-${var.environment}"
  shard_count      = 1
  retention_period = var.retention_period_hours

  encryption_type = "KMS"
  kms_key_id      = aws_kms_key.kinesis.arn

  tags = {
    Name        = "network-fault-correlated-events-${var.environment}"
    Environment = var.environment
    Stream      = "stream-2-correlated"
  }
}

# ─── DYNAMODB TABLES ─────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "device_topology" {
  name         = "device-topology-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"

  attribute {
    name = "device_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = "device-topology-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_dynamodb_table" "fault_status" {
  name         = "fault-status-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pop_id"
  range_key    = "timestamp"

  attribute {
    name = "pop_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  tags = {
    Name        = "fault-status-${var.environment}"
    Environment = var.environment
  }
}

# ─── SECURITY GROUP — LAMBDA ─────────────────────────────────────────────────
resource "aws_security_group" "lambda" {
  name        = "fault-correlation-lambda-sg-${var.environment}"
  description = "Lambda enrichment and alerting functions"
  vpc_id      = aws_vpc.correlation_engine.id

  egress {
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    source_security_group_id = aws_security_group.vpc_endpoints.id
    description              = "HTTPS to VPC endpoints only"
  }

  tags = {
    Name        = "fault-correlation-lambda-sg-${var.environment}"
    Environment = var.environment
  }
}

# ─── SNS TOPICS ──────────────────────────────────────────────────────────────
resource "aws_sns_topic" "device_fault" {
  name = "fault-correlation-device-fault-${var.environment}"

  tags = {
    Name        = "fault-correlation-device-fault-${var.environment}"
    Environment = var.environment
    Scope       = "device"
  }
}

resource "aws_sns_topic" "pop_fault" {
  name = "fault-correlation-pop-fault-${var.environment}"

  tags = {
    Name        = "fault-correlation-pop-fault-${var.environment}"
    Environment = var.environment
    Scope       = "pop"
  }
}

resource "aws_sns_topic" "region_fault" {
  name = "fault-correlation-region-fault-${var.environment}"

  tags = {
    Name        = "fault-correlation-region-fault-${var.environment}"
    Environment = var.environment
    Scope       = "region"
  }
}

# ─── IAM — LAMBDA ENRICHMENT ROLE ────────────────────────────────────────────
resource "aws_iam_role" "lambda_enrichment" {
  name = "fault-correlation-enrichment-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "fault-correlation-enrichment-role-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "lambda_enrichment" {
  name = "fault-correlation-enrichment-policy-${var.environment}"
  role = aws_iam_role.lambda_enrichment.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListStreams"
        ]
        Resource = aws_kinesis_stream.raw_signals.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord", "kinesis:PutRecords"]
        Resource = aws_kinesis_stream.correlated_events.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.device_topology.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.kinesis.arn, aws_kms_key.dynamodb.arn]
      }
    ]
  })
}

# ─── IAM — LAMBDA ALERTING ROLE ──────────────────────────────────────────────
resource "aws_iam_role" "lambda_alerting" {
  name = "fault-correlation-alerting-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "fault-correlation-alerting-role-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "lambda_alerting" {
  name = "fault-correlation-alerting-policy-${var.environment}"
  role = aws_iam_role.lambda_alerting.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListStreams"
        ]
        Resource = aws_kinesis_stream.correlated_events.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [
          aws_sns_topic.device_fault.arn,
          aws_sns_topic.pop_fault.arn,
          aws_sns_topic.region_fault.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.fault_status.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.kinesis.arn
      }
    ]
  })
}
