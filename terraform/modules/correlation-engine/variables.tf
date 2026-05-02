variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC — must not overlap with other regional VPCs"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "shard_count" {
  description = "Number of Kinesis shards for Stream 1 (raw signals)"
  type        = number
  default     = 2

  validation {
    condition     = var.shard_count >= 1 && var.shard_count <= 10
    error_message = "shard_count must be between 1 and 10."
  }
}

variable "retention_period_hours" {
  description = "Kinesis stream retention period in hours"
  type        = number
  default     = 24

  validation {
    condition     = contains([24, 48, 72, 168], var.retention_period_hours)
    error_message = "retention_period_hours must be 24, 48, 72, or 168."
  }
}

variable "pop_fault_threshold_percent" {
  description = "Percentage of devices alarming before a POP fault is declared"
  type        = number
  default     = 60

  validation {
    condition     = var.pop_fault_threshold_percent >= 50 && var.pop_fault_threshold_percent <= 100
    error_message = "pop_fault_threshold_percent must be between 50 and 100."
  }
}

variable "lambda_memory_mb" {
  description = "Lambda function memory allocation in MB"
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048], var.lambda_memory_mb)
    error_message = "lambda_memory_mb must be 256, 512, 1024, or 2048."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
