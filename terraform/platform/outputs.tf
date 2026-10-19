output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "docdb_endpoint" {
  value = aws_docdb_cluster.this.endpoint
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "ssm_parameters" {
  description = "App secrets for External Secrets to sync"
  value       = [aws_ssm_parameter.mongo_uri.name, aws_ssm_parameter.redis_uri.name, aws_ssm_parameter.jwt_secret.name]
}

output "argocd_ui" {
  value = "kubectl -n argocd port-forward svc/argocd-server 8080:443   # then open <https://localhost:8080>"
}

output "argocd_admin_password" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
