# Permanent resources: survive every `terraform destroy` of the platform stack.

data "aws_caller_identity" "current" {}

locals {
  services = ["frontend", "auth-service", "tender-service", "quotation-service"]
}

# ---------------------------------------------------------------------------
# Terraform state bucket for the platform stack
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = "tenderflow-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Source repos
# ---------------------------------------------------------------------------
resource "aws_codecommit_repository" "backend" {
  repository_name = "tenderflow-backend"
  description     = "TenderFlow backend: monolith + auth/tender/quotation services"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_codecommit_repository" "frontend" {
  repository_name = "tenderflow-frontend"
  description     = "TenderFlow frontend (Vite app served by nginx)"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_codecommit_repository" "infra" {
  repository_name = "tenderflow-infra"
  description     = "Terraform + Helm + per-env config (ArgoCD source of truth)"

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Container registries (permanent so images survive cluster teardown)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "svc" {
  for_each = toset(local.services)

  name                 = "tenderflow/${each.key}"
  image_tag_mutability = "IMMUTABLE" # tags are commit SHAs - never overwrite one

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
