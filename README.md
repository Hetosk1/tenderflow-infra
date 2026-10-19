# TenderFlow on AWS — company-style platform, built from scratch

> **For Claude Code:** this file is the handoff from a planning conversation. Read it fully before acting.
> Some "done" items were reported by the user but not verified — run the checks in [Verify current state first](#verify-current-state-first) before changing anything.

## Goal

A personal, educational weekend project: rebuild the *shape* of a real company platform (AKS + Azure DevOps + ArgoCD GitOps) on **AWS**, using the user's own team project **TenderFlow** as the workload.

**Ground rules**

- **Nothing is copied from the user's employer.** No configs, repos, names, or secrets. Everything here is written from scratch.
- **Cost discipline.** Personal AWS account. The platform stack is destroyed at the end of every session. Pin tool/chart versions that are at least ~2 weeks old.
- **Ask before** running `terraform apply`, `terraform destroy`, `destroy.sh`, `bootstrap.sh`, `git push`, or any command that creates AWS resources or costs money.
- **Never commit secrets.** Secrets live in SSM Parameter Store (`/tenderflow/*`) and reach pods via External Secrets.
- **Mapping to learn:** AKS → EKS · ACR → ECR · Azure Repos → CodeCommit · Azure DevOps pipeline + release task → CodePipeline + CodeBuild (build → push → bump tag in infra repo) · ArgoCD syncing from an infra repo → same, on EKS.

## Environment

| Thing | Value |
|---|---|
| Region | `ap-south-1` (Mumbai) |
| AWS auth | IAM Identity Center (SSO), CLI profile **`tenderflow`** → `export AWS_PROFILE=tenderflow` |
| Machine | MacBook Air (Apple Silicon) → **always build images with `--platform linux/amd64`** |
| Local infra folder | `~/Desktop/DevOps` (contains `terraform/bootstrap`, `terraform/platform`). Assumed to be the `tenderflow-infra` git repo — verify with `git remote -v` |
| Kubernetes | EKS `1.35` (must stay in EKS *standard* support — extended support costs ~6×) |
| Nodes | 2 × `t3.medium`, AL2023, managed node group |

## Architecture

```
 dev pushes ──► CodeCommit: tenderflow-backend ──► CodePipeline ──► CodeBuild ──► ECR (tenderflow/<svc>:<shortsha>)
                CodeCommit: tenderflow-frontend ─► CodePipeline ──► CodeBuild ──┘        │
                                                                                         ▼
                                                    CodeBuild commits new tag ──► CodeCommit: tenderflow-infra
                                                                                         │
                                                              ArgoCD (on EKS) watches ◄──┘
                                                                     │
           ALB (AWS LB Controller) ──► /auth/*      → auth-service      :4001
                                       /tenders/*   → tender-service    :4002
                                       /quotation/* → quotation-service :4003
                                       /            → frontend (nginx)  :80
                                                                     │
                      DocumentDB (Mongo-compatible, TLS) ◄───────────┤
                      ElastiCache Redis ◄────────────────────────────┤
                      SSM Parameter Store /tenderflow/* ──► External Secrets ──► Secret "tenderflow-secrets"
```

CodePipeline **never deploys to the cluster**. It stops at the tag bump; ArgoCD deploys (GitOps).

## Repositories

| Repo | Where | Contents |
|---|---|---|
| `Hetosk1/tenderflow` | GitHub | Team monorepo, source of truth for app code. Teammates keep working here. Contains a legacy `backend-tenderflow/` folder — **ignore it, it is not deployed** (old pre-split version). |
| `tenderflow-backend` | CodeCommit | The **contents of the `microservices/` folder** at repo root: `auth-service/`, `tender-service/`, `quotation-service/` |
| `tenderflow-frontend` | CodeCommit | Contents of `tenderflow-pro/` (Vite app, served by nginx via `Dockerfile.prod`) |
| `tenderflow-infra` | CodeCommit | Terraform + Helm chart + per-env values + ArgoCD apps (this repo) |

Git → CodeCommit auth uses the AWS credential helper (no username/password). Per repo:

```bash
git config --local credential.helper ''
git config --local --add credential.helper '!aws codecommit credential-helper --profile tenderflow $@'
git config --local credential.UseHttpPath true
```

## Services (only 4 images — there is NO monolith backend)

| Service | Port | Secrets (from `tenderflow-secrets`) | Plain env | Health route | Status |
|---|---|---|---|---|---|
| auth-service | 4001 | `MONGO_URI`, `JWT_SECRET` | `PORT` | `/heath` (typo in `server.js`) | values + ArgoCD app written |
| tender-service | 4002 | `MONGO_URI`, `REDIS_URI`, `JWT_SECRET` | `PORT`, `QUOTATION_SERVICE_URL=http://quotation-service:4003` | **none — must add `GET /health`** | not started |
| quotation-service | 4003 | `MONGO_URI`, `REDIS_URI`, `JWT_SECRET` | `PORT` | **none — must add `GET /health`** | not started |
| frontend | 80 | — | — (Vite bakes API URL at build time → use relative paths) | `/` | not started; needs its own small nginx chart |

Route prefixes already match each service's `app.use(...)` mount, so the ALB acts as the API gateway with no code changes.

## Repo layout (target)

```
tenderflow-infra/
├── terraform/
│   ├── bootstrap/        # PERMANENT, local state: S3 state bucket, 3 CodeCommit repos, ECR repos
│   └── platform/         # DESTROYED EVERY SESSION, S3 backend: VPC, EKS, add-ons, DocumentDB, ElastiCache, SSM params
│       ├── versions.tf   # aws ~> 6.28, helm ~> 3.2, S3 backend with use_lockfile, provider "helm" (v3 syntax: kubernetes = { exec = {...} })
│       ├── main.tf       # VPC (2 AZ, single NAT) + EKS module v21 + EKS add-ons incl. aws-ebs-csi-driver (default gp3 SC)
│       ├── addons.tf     # Pod Identity roles + Helm: aws-load-balancer-controller, external-secrets, argo-cd
│       ├── destroy.sh    # USE INSTEAD OF `terraform destroy` (deletes ALBs/PVCs via k8s first)
│       └── (user-added)  # DocumentDB, ElastiCache, SSM params — not reviewed yet, see Known issues
├── charts/node-service/  # one reusable chart for the 3 Node services (Deployment + Service, probes, secretEnv, optional DocumentDB CA mount)
├── envs/dev/<service>/values.yaml
├── platform-config/dev/  # ExternalSecret: SSM → Secret "tenderflow-secrets" (MONGO_URI, REDIS_URI, JWT_SECRET)
├── argocd/apps/          # child Applications (platform-config, auth-service, ...)
└── bootstrap/            # run each session after apply: ClusterSecretStore, ArgoCD repo creds (ExternalSecret), DocumentDB CA ConfigMap, root app
```

## Where we've reached

**Phase 0: Account setup — done (reported)**
SSO admin user, CLI profile `tenderflow`, root MFA, budget alert, tools installed (aws, terraform, kubectl, helm).

**Phase 1: Terraform foundation — done (reported)**
- `bootstrap/` applied: S3 state bucket `tenderflow-tfstate-<account_id>`, CodeCommit repos `tenderflow-backend`, `tenderflow-frontend`, `tenderflow-infra` (all `prevent_destroy`), ECR repos `tenderflow/<svc>` (IMMUTABLE tags, scan on push, keep last 10).
- `platform/` applied: VPC + EKS `tenderflow`.

**Phase 2a: Cluster add-ons — done (applied successfully after fixes)**
- AWS Load Balancer Controller chart `3.5.0`, External Secrets chart `2.11.0`, Argo CD chart `10.9.2`, EBS CSI add-on with default gp3 StorageClass, all IAM via EKS Pod Identity (module `terraform-aws-modules/eks-pod-identity/aws` `2.9.0`).
- Fixes already applied: removed `<...>` around chart repository URLs (copy-paste artifact); added `provider "helm"` block; added `depends_on = [helm_release.aws_lb_controller]` to external-secrets and argocd (LBC webhook race).
- User **also added on their own**: DocumentDB, ElastiCache Redis, SSM params. Last `terraform output`:
  - `docdb_endpoint = tenderflow.cluster-….ap-south-1.docdb.amazonaws.com`
  - `redis_endpoint = master.tenderflow.….aps1.cache.amazonaws.com` (the `master.` prefix suggests in-transit TLS)
  - `ssm_parameters = /tenderflow/mongo-uri, /tenderflow/redis-uri, /tenderflow/jwt-secret`

**Phase 2b: First app deploy (auth-service) — files generated, NOT confirmed applied**
Generated as `phase2b.zip` (chart, `envs/dev/auth-service`, `platform-config/dev`, `argocd/apps`, `bootstrap/`). Unknown whether the user has: unzipped it into the repo, replaced `ACCOUNT_ID` in `envs/dev/auth-service/values.yaml`, created the ArgoCD CodeCommit IAM user + SSM creds, pushed the auth-service image, committed/pushed, or run `bootstrap.sh`.

**Phase 3 (pipeline), Phase 4 (break it on purpose), stretch goals — not started.**

## Verify current state first

```bash
export AWS_PROFILE=tenderflow
aws sts get-caller-identity
cd ~/Desktop/DevOps && git status && git remote -v && git log --oneline -5
ls charts envs argocd bootstrap platform-config 2>/dev/null        # is phase2b in the repo?
grep -rn 'ACCOUNT_ID' envs bootstrap terraform 2>/dev/null           # unreplaced placeholders
grep -n '"backend"' terraform/bootstrap/main.tf                      # cleanup item below
ls terraform/platform/ && grep -ln 'docdb\|elasticache' terraform/platform/*.tf
aws ssm get-parameters-by-path --path /tenderflow --recursive --query 'Parameters[].Name'
aws ecr describe-images --repository-name tenderflow/auth-service --query 'imageDetails[].imageTags' 2>/dev/null
aws eks describe-cluster --name tenderflow --query cluster.status 2>/dev/null   # is the cluster up right now?
```

## Known issues / what needs fixing

Ordered roughly by priority.

1. **Remove `"backend"` from `local.services`** in `terraform/bootstrap/main.tf`. There is no monolith; this leaves an unused `tenderflow/backend` ECR repo. (Empty repo, safe to destroy via plan.)
2. **Review the user-added DocumentDB / ElastiCache / SSM Terraform:**
   - `skip_final_snapshot = true` on DocumentDB, otherwise `destroy.sh` fails.
   - DocumentDB security group must allow **27017 from the EKS node security group** (`module.eks.node_security_group_id`); ElastiCache SG must allow **6379** likewise.
   - `MONGO_URI` must be DocumentDB-compatible:
     `mongodb://USER:PASS@<docdb_endpoint>:27017/tenderflow?tls=true&tlsCAFile=/certs/global-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false`
     (the chart mounts the CA at `/certs/global-bundle.pem` when `docdbCA: true`; `bootstrap.sh` creates the `docdb-ca` ConfigMap).
   - If ElastiCache transit encryption is on, `REDIS_URI` must be `rediss://…` (plus auth token if configured).
   - SSM params should be `SecureString`; values end up in Terraform state (S3, encrypted) — acceptable for this project.
3. **Health endpoints:** add `GET /health` to tender-service and quotation-service (app code). auth-service uses `/heath`; the chart probe matches it — fix both together if renaming. App changes should also go back to the team's GitHub repo.
4. **Pod density:** t3.medium allows 17 pods/node; system add-ons already use ~26 of 34. Before deploying all services, enable VPC CNI prefix delegation (vpc-cni add-on `configuration_values` with `ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1`; nodes must be replaced to pick up new max-pods) or move to larger instances.
5. **Cosmetic:** `terraform/platform/outputs.tf` `argocd_ui` string contains `<https://localhost:8080>` brackets.
6. **ArgoCD repo access (one-time, if not done):** IAM user `argocd-codecommit` with `codecommit:GitPull` on `tenderflow-infra` only, HTTPS Git service-specific credential, stored as SSM SecureStrings `/tenderflow/argocd/git-username` and `/tenderflow/argocd/git-password` (read by `bootstrap/argocd-repo-secret.yaml`). Ideally codify the IAM user in `bootstrap/` Terraform later.

## Next steps

- [ ] Finish Phase 2b for auth-service: verify → fix placeholders → push image (`docker buildx build --platform linux/amd64 -t <acct>.dkr.ecr.ap-south-1.amazonaws.com/tenderflow/auth-service:manual-1 --push .`) → commit/push infra → `./bootstrap/bootstrap.sh` → app Synced/Healthy, logs show "Connected to Database", `curl localhost:4001/heath` via port-forward works.
- [ ] Prefix delegation (issue 4).
- [ ] tender-service + quotation-service: `envs/dev/<svc>/values.yaml` + `argocd/apps/<svc>.yaml` (same chart, `docdbCA: true`, secretEnv per table above).
- [ ] Frontend: small nginx chart (or generalize `node-service` → `web-service`), port 80, health `/`.
- [ ] Ingress: one ALB, `ingressClassName: alb`, `alb.ingress.kubernetes.io/scheme: internet-facing`, `target-type: ip`, path rules per routing table, `/` last. Put it in an ArgoCD-managed app.
- [ ] **Phase 3 pipeline (Terraform, in `bootstrap/` so it survives teardown):**
  - Two CodeBuild projects (privileged mode on) + two CodePipelines (Source: CodeCommit; Build: CodeBuild). No deploy stage.
  - CodeBuild role: ECR push on `tenderflow/*`, `codecommit:GitPull`/`GitPush` on `tenderflow-infra` only, CloudWatch Logs.
  - `buildspec.yml` per repo (a draft exists from the conversation): ECR login, build with tag = short commit SHA, push, then clone `tenderflow-infra`, `yq -i '.image.tag = "<sha>"' envs/dev/<svc>/values.yaml`, commit, **`git pull --rebase` then push** (two pipelines can race), and **guard `post_build` with `CODEBUILD_BUILD_SUCCEEDING`**. Backend repo build contexts are `auth-service/`, `tender-service/`, `quotation-service/` (repo root = microservices folder). Frontend runs `npm ci && npm run build` before `docker build -f Dockerfile.prod`.
  - Consider ECR pull-through cache for Docker Hub base images (rate limits from shared CodeBuild IPs).
- [ ] Phase 4, break it on purpose: bad image → readiness blocks rollout → `git revert` in infra repo; delete pod / drain node; `kubectl edit` → ArgoCD self-heal reverts.
- [ ] Stretch: `prod` env + manual approval stage in CodePipeline; Prometheus/Grafana; HPA on tender-service; README architecture diagram for portfolio.

## Session runbook

**Start**

```bash
aws sso login --profile tenderflow
export AWS_PROFILE=tenderflow
cd ~/Desktop/DevOps/terraform/platform
terraform apply
aws eks update-kubeconfig --region ap-south-1 --name tenderflow   # endpoint changes every rebuild
cd ~/Desktop/DevOps && ./bootstrap/bootstrap.sh
kubectl get applications -n argocd
```

**ArgoCD UI**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443    # https://localhost:8080, user admin
```

**End (every session)**

```bash
cd ~/Desktop/DevOps/terraform/platform && ./destroy.sh        # NOT plain terraform destroy
```

`bootstrap/` Terraform (state bucket, CodeCommit, ECR) is never destroyed; keep its local `terraform.tfstate` safe (gitignored).

## Gotchas already hit (don't repeat)

- Copying from rendered markdown wrapped URLs in `<...>` → Helm "invalid chart URL format".
- Helm provider v3 syntax is `kubernetes = { ... exec = { ... } }` (with `=`), not v2 block syntax.
- LBC webhook race: anything creating Services must `depends_on` the LBC Helm release.
- Failed Helm release blocks re-create ("cannot re-use a name") → `helm uninstall <name> -n <ns>` then apply.
- Stale kubeconfig after rebuild → "no such host" → `aws eks update-kubeconfig`.
- macOS Keychain intercepts CodeCommit HTTPS → 403; clear credential helper per repo (see Repositories).
- `post_build` in CodeBuild runs even when `build` fails.

## Pinned versions

| Component | Version |
|---|---|
| Terraform | ≥ 1.10 (S3 native locking) |
| AWS provider | ~> 6.28 |
| Helm provider | ~> 3.2 |
| `terraform-aws-modules/vpc/aws` | ~> 6.0 |
| `terraform-aws-modules/eks/aws` | ~> 21.0 (inputs: `name`, `kubernetes_version`, `endpoint_public_access`, `enable_cluster_creator_admin_permissions`, `addons`) |
| `terraform-aws-modules/eks-pod-identity/aws` | 2.9.0 |
| aws-load-balancer-controller chart | 3.5.0 |
| external-secrets chart | 2.11.0 (API `external-secrets.io/v1`) |
| argo-cd chart | 10.9.2 |
| EKS Kubernetes | 1.35 |