# Cluster add-ons. Installed by Terraform so a fresh `apply` brings back a
# fully working platform; ArgoCD then takes over everything app-related.

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# IAM for add-ons via EKS Pod Identity (no OIDC/IRSA plumbing needed)
# ---------------------------------------------------------------------------

# Role only; the association is created by the EKS add-on itself (main.tf)
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name                      = "tenderflow-ebs-csi"
  attach_aws_ebs_csi_policy = true
}

module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name                            = "tenderflow-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name                           = "tenderflow-external-secrets"
  attach_external_secrets_policy = true
  # Read-only access to /tenderflow/* in SSM Parameter Store, nothing else
  external_secrets_ssm_parameter_arns = [
    "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/tenderflow/*"
  ]
  external_secrets_create_permission = false

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller: turns Ingress objects into ALBs
# ---------------------------------------------------------------------------
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    region      = var.region
    vpcId       = module.vpc.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller" # must match the pod identity association
    }
  })]

  depends_on = [module.eks, module.lb_controller_pod_identity]
}

# ---------------------------------------------------------------------------
# External Secrets Operator: syncs SSM parameters into Kubernetes Secrets
# ---------------------------------------------------------------------------
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.11.0"

  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "external-secrets" # must match the pod identity association
    }
  })]

  depends_on = [module.eks, module.external_secrets_pod_identity, helm_release.aws_lb_controller]
}

# ---------------------------------------------------------------------------
# ArgoCD: default install, reached via port-forward for now
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.2"

  depends_on = [module.eks, helm_release.aws_lb_controller]
}