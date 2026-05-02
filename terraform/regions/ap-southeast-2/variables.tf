variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "shard_count" {
  type = number
}

variable "retention_period_hours" {
  type    = number
  default = 24
}

variable "lambda_memory_mb" {
  type    = number
  default = 512
}
