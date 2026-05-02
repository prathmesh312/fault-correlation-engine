module "correlation_engine" {
  source = "../../modules/correlation-engine"

  environment            = var.environment
  aws_region             = "ap-southeast-2"
  vpc_cidr               = var.vpc_cidr
  shard_count            = var.shard_count
  retention_period_hours = var.retention_period_hours
  lambda_memory_mb       = var.lambda_memory_mb

  tags = {
    Region  = "ap-southeast-2"
    Tier    = "primary"
  }
}
