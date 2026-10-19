# TenderFlow Infrastructure (Terraform)

AWS infrastructure for TenderFlow, split into two stacks so that expensive
compute can be torn down daily while code, images and state survive.

| Stack        | What it creates                                 | State                         | Lifecycle                     |
| ------------ | ----------------------------------------------- | ----------------------------- | ----------------------------- |
| `bootstrap/` | S3 state bucket, CodeCommit repos, ECR repos    | Local (`terraform.tfstate`)   | Permanent - apply once        |
| `platform/`  | VPC (2 AZs, 1 NAT), EKS cluster + node group    | S3 bucket from `bootstrap/`   | Destroy at end of each session |

- **Account:** `935262984400`
- **Region:** `ap-south-1` (Mumbai) - switch the console to this region or you won't see anything
- **Terraform:** `>= 1.10` · **AWS provider:** `~> 6.0`

## Layout

```
terraform/
├── bootstrap/
│   ├── versions.tf   # provider, region, default tags (local state)
│   ├── main.tf       # S3 tfstate bucket, CodeCommit, ECR + lifecycle policies
│   └── outputs.tf    # bucket name, repo clone URLs, ECR URLs
└── platform/
    ├── versions.tf   # provider + S3 backend (native lockfile, no DynamoDB)
    ├── variables.tf  # region, kubernetes_version, node_instance_type
    ├── main.tf       # VPC module + EKS module
    └── outputs.tf    # cluster name/endpoint, kubectl config command
```

## Prerequisites

- Terraform >= 1.10, AWS CLI v2, kubectl
- AWS credentials for an IAM identity with permissions for S3, ECR, CodeCommit,
  VPC/EC2, EKS and IAM (currently IAM user `terraform-s3`)
- Optional: `aws configure set region ap-south-1`

## 1. Bootstrap (one time)

```bash
cd bootstrap
terraform init
terraform plan
terraform apply
terraform output
```

Creates:

- **S3:** `tenderflow-tfstate-935262984400` - versioned, AES256-encrypted, public access blocked
- **CodeCommit:** `tenderflow-backend`, `tenderflow-frontend`, `tenderflow-infra`
- **ECR:** `tenderflow/{frontend,backend,auth-service,tender-service,quotation-service}`
  - Immutable tags (use commit SHAs), scan on push, keeps the last 10 images

The bucket and CodeCommit repos have `prevent_destroy = true`.

> **Keep `bootstrap/terraform.tfstate` safe.** It is the only record of these
> resources and must not be committed to git.

## 2. Platform (each session)

`platform/versions.tf` points its backend at the bootstrap bucket:

```hcl
backend "s3" {
  bucket       = "tenderflow-tfstate-935262984400"
  key          = "platform/terraform.tfstate"
  region       = "ap-south-1"
  encrypt      = true
  use_lockfile = true
}
```

Spin up:

```bash
cd platform
terraform init        # add -reconfigure after changing the backend block
terraform plan
terraform apply       # ~15-20 min, mostly the EKS control plane
```

Connect kubectl:

```bash
$(terraform output -raw configure_kubectl)
kubectl get nodes     # expect 2 Ready nodes
```

What you get:

- **VPC** `10.0.0.0/16` across 2 AZs
  - Private subnets `10.0.0.0/20`, `10.0.16.0/20` (nodes live here)
  - Public subnets `10.0.48.0/24`, `10.0.49.0/24`
  - Single NAT gateway; subnets tagged for the AWS Load Balancer Controller
- **EKS** cluster `tenderflow`, Kubernetes `1.35`, public API endpoint
  - Add-ons: coredns, kube-proxy, vpc-cni, eks-pod-identity-agent
  - Managed node group: `t3.medium`, AL2023, min 1 / desired 2 / max 3
  - The identity that runs `apply` becomes cluster admin

### Variables

| Name                 | Default      | Notes                                              |
| -------------------- | ------------ | -------------------------------------------------- |
| `region`             | `ap-south-1` |                                                    |
| `kubernetes_version` | `1.35`       | Keep in EKS standard support (1.35 ends Mar 2027) |
| `node_instance_type` | `t3.medium`  |                                                    |

Check supported versions:

```bash
aws eks describe-cluster-versions --region ap-south-1 \
  --query 'clusterVersions[].[clusterVersion,versionStatus,endOfStandardSupportDate]' --output text
```

## 3. Tear down (end of every session)

```bash
# First delete anything Kubernetes created in AWS (LoadBalancer Services, Ingresses),
# otherwise leftover load balancers block VPC deletion.
kubectl get svc,ingress -A

cd platform
terraform destroy
```

This leaves `bootstrap/` resources (state bucket, repos, images) untouched.

## Cost

Rough on-demand cost while `platform/` is up:

| Item                 | Approx. cost   |
| -------------------- | -------------- |
| EKS control plane    | $0.10 / hr     |
| NAT gateway          | ~$0.06 / hr + data |
| 2 × t3.medium        | ~$0.09 / hr    |
| **Total**            | **~$0.25 / hr (~$6 / day)** |

Bootstrap resources cost cents per month (S3 storage, ECR image storage).

## Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| `Missing required provider` on validate | Run `terraform init` in that folder first |
| `S3 bucket ... does not exist` on init | Backend `bucket` still has a placeholder, or the file isn't saved. Fix it, then `terraform init -reconfigure` |
| `Reference to undeclared resource` | An output references a resource name that isn't defined in `main.tf` |
| Apply succeeded but nothing in console | Console is on the wrong region - switch to ap-south-1 |
| `terraform destroy` hangs on VPC/subnets | Leftover load balancers or ENIs from Kubernetes - delete Services/Ingresses first |

## .gitignore

Add this at the repo root:

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
crash.log
.DS_Store
```

Commit `.terraform.lock.hcl` so provider versions are pinned for everyone.
