terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "fault-correlation-terraform-state"
    key            = "regions/eu-central-1/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      System     = "fault-correlation-engine"
      ManagedBy  = "terraform"
      Repository = "fault-correlation-engine"
    }
  }
}
