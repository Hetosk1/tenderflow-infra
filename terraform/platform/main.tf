# Destroyable resources: VPC + EKS. Run `terraform destroy` at the end of every session.

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name     = "tenderflow"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
}

# ---------------------------------------------------------------------------
# VPC: 2 AZs, public + private subnets, ONE NAT gateway (cost saver)
# ---------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(local.vpc_cidr, 4, i)]      # 10.0.0.0/20, 10.0.16.0/20
  public_subnets  = [for i, _ in local.azs : cidrsubnet(local.vpc_cidr, 8, i + 48)] # 10.0.48.0/24, 10.0.49.0/24

  enable_nat_gateway = true
  single_nat_gateway = true

  # Tags the AWS Load Balancer Controller uses to find subnets (Phase 2)
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # Reach the API from your laptop. Optional hardening:
  # endpoint_public_access_cidrs = ["<your-ip>/32"]
  endpoint_public_access = true

  # Makes your SSO admin identity a cluster admin so kubectl works immediately
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
      # Creates a default gp3 StorageClass so Mongo/Redis PVCs just work
      configuration_values = jsonencode({
        defaultStorageClass = { enabled = true }
      })
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
  }
}
