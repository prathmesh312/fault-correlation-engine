output "vpc_id" {
  description = "VPC ID for the correlation engine"
  value       = aws_vpc.correlation_engine.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for Lambda and other compute"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "kinesis_stream1_arn" {
  description = "ARN of Kinesis Stream 1 (raw device signals)"
  value       = aws_kinesis_stream.raw_signals.arn
}

output "kinesis_stream1_name" {
  description = "Name of Kinesis Stream 1"
  value       = aws_kinesis_stream.raw_signals.name
}

output "kinesis_stream2_arn" {
  description = "ARN of Kinesis Stream 2 (correlated fault events)"
  value       = aws_kinesis_stream.correlated_events.arn
}

output "kinesis_stream2_name" {
  description = "Name of Kinesis Stream 2"
  value       = aws_kinesis_stream.correlated_events.name
}

output "dynamodb_topology_table_name" {
  description = "DynamoDB topology table name"
  value       = aws_dynamodb_table.device_topology.name
}

output "dynamodb_fault_status_table_name" {
  description = "DynamoDB fault status table name"
  value       = aws_dynamodb_table.fault_status.name
}

output "lambda_enrichment_role_arn" {
  description = "IAM role ARN for enrichment Lambda"
  value       = aws_iam_role.lambda_enrichment.arn
}

output "lambda_alerting_role_arn" {
  description = "IAM role ARN for alerting Lambda"
  value       = aws_iam_role.lambda_alerting.arn
}

output "lambda_security_group_id" {
  description = "Security group ID for Lambda functions"
  value       = aws_security_group.lambda.id
}

output "sns_device_fault_arn" {
  description = "SNS topic ARN for device fault events"
  value       = aws_sns_topic.device_fault.arn
}

output "sns_pop_fault_arn" {
  description = "SNS topic ARN for POP fault events"
  value       = aws_sns_topic.pop_fault.arn
}

output "sns_region_fault_arn" {
  description = "SNS topic ARN for region fault events"
  value       = aws_sns_topic.region_fault.arn
}

output "kms_kinesis_key_arn" {
  description = "KMS key ARN for Kinesis encryption"
  value       = aws_kms_key.kinesis.arn
}
