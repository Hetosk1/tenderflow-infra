output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "backend_repo_clone_url" {
  value = aws_codecommit_repository.backend.clone_url_http
}

output "frontend_repo_clone_url" {
  value = aws_codecommit_repository.frontend.clone_url_http
}

output "infra_repo_clone_url" {
  value = aws_codecommit_repository.infra.clone_url_http
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.svc : k => r.repository_url }
}
