terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Local state on purpose: this stack creates the S3 bucket the other stack uses.
  # Keep terraform.tfstate safe (it's gitignored) - this stack is rarely touched.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "tenderflow"
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-south-1"
}
