# CI: CodeCommit push -> CodePipeline -> CodeBuild (build, push to ECR, bump tag in tenderflow-infra).
# There is deliberately NO deploy stage: ArgoCD sees the tag change in git and deploys.
# Lives in bootstrap/ so pipelines survive every platform teardown (they cost ~nothing while idle).

locals {
  account_id = data.aws_caller_identity.current.account_id

  # One pipeline per source repo. Each repo has its own buildspec.yml at its root.
  pipelines = {
    backend = {
      repo         = aws_codecommit_repository.backend
      compute_type = "BUILD_GENERAL1_SMALL"
    }
    frontend = {
      repo         = aws_codecommit_repository.frontend
      compute_type = "BUILD_GENERAL1_SMALL"
    }
  }
}

# ---------------------------------------------------------------------------
# Artifact bucket: CodePipeline hands the source zip to CodeBuild through it.
# Throwaway contents, so force_destroy and a short expiry.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "tenderflow-pipeline-artifacts-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"
    filter {}

    expiration {
      days = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Build logs (explicit group so we control retention; default is "never expire")
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = local.pipelines

  name              = "/aws/codebuild/tenderflow-${each.key}"
  retention_in_days = 7
}

# ---------------------------------------------------------------------------
# CodeBuild role: push images, bump the tag in tenderflow-infra, write logs. Nothing else.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "codebuild" {
  name = "tenderflow-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "tenderflow-codebuild"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # cannot be scoped to a repo
      },
      {
        Sid    = "EcrPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
        ]
        Resource = [for r in aws_ecr_repository.svc : r.arn]
      },
      {
        Sid      = "BumpTagInInfraRepo"
        Effect   = "Allow"
        Action   = ["codecommit:GitPull", "codecommit:GitPush"]
        Resource = aws_codecommit_repository.infra.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [for g in aws_cloudwatch_log_group.codebuild : "${g.arn}:*"]
      },
      {
        Sid      = "ReadSourceArtifact"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CodeBuild projects: Docker needs privileged mode
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "this" {
  for_each = local.pipelines

  name          = "tenderflow-${each.key}"
  description   = "Build ${each.value.repo.repository_name}, push to ECR, bump tag in tenderflow-infra"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20 # minutes

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml" # at the root of each source repo
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = each.value.compute_type
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0" # AL2023, x86_64 = matches EKS nodes
    privileged_mode = true                                            # required for docker build

    environment_variable {
      name  = "ECR_REGISTRY"
      value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    }
    environment_variable {
      name  = "INFRA_REPO_URL"
      value = aws_codecommit_repository.infra.clone_url_http
    }
    environment_variable {
      name  = "ENV_NAME"
      value = "dev"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild[each.key].name
    }
  }
}

# ---------------------------------------------------------------------------
# CodePipeline role: read the source repo, run the build, use the artifact bucket
# ---------------------------------------------------------------------------
resource "aws_iam_role" "codepipeline" {
  name = "tenderflow-codepipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "tenderflow-codepipeline"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSourceRepos"
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:GetRepository",
          "codecommit:UploadArchive",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:CancelUploadArchive",
        ]
        Resource = [for p in local.pipelines : p.repo.arn]
      },
      {
        Sid      = "RunBuilds"
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [for b in aws_codebuild_project.this : b.arn]
      },
      {
        Sid      = "ArtifactBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [aws_s3_bucket.pipeline_artifacts.arn, "${aws_s3_bucket.pipeline_artifacts.arn}/*"]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Pipelines: Source (CodeCommit main) -> Build (CodeBuild). No deploy stage.
# ---------------------------------------------------------------------------
resource "aws_codepipeline" "this" {
  for_each = local.pipelines

  name           = "tenderflow-${each.key}"
  role_arn       = aws_iam_role.codepipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED" # pushes run one after another instead of superseding each other

  # A new pipeline runs immediately on creation; without this it can start before
  # its role has permissions and fail with "not authorized to perform codecommit:GetBranch"
  depends_on = [aws_iam_role_policy.codepipeline]

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.pipeline_artifacts.bucket
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      namespace        = "SourceVariables" # exposes #{SourceVariables.CommitId}
      output_artifacts = ["source"]

      configuration = {
        RepositoryName       = each.value.repo.repository_name
        BranchName           = "main"
        PollForSourceChanges = "false" # EventBridge rule below triggers it instantly instead
      }
    }
  }

  stage {
    name = "Build"

    action {
      name            = "BuildPushBump"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.this[each.key].name
        # The zip from CodeCommit has no .git folder, so pass the commit SHA in explicitly
        EnvironmentVariables = jsonencode([{
          name  = "COMMIT_ID"
          value = "#{SourceVariables.CommitId}"
          type  = "PLAINTEXT"
        }])
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Trigger: push to main -> EventBridge -> start the pipeline
# ---------------------------------------------------------------------------
resource "aws_iam_role" "events" {
  name = "tenderflow-pipeline-trigger"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "events" {
  name = "tenderflow-pipeline-trigger"
  role = aws_iam_role.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codepipeline:StartPipelineExecution"
      Resource = [for p in aws_codepipeline.this : p.arn]
    }]
  })
}

resource "aws_cloudwatch_event_rule" "push_to_main" {
  for_each = local.pipelines

  name        = "tenderflow-${each.key}-push-to-main"
  description = "Start tenderflow-${each.key} pipeline on push to main"

  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [each.value.repo.arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })
}

resource "aws_cloudwatch_event_target" "push_to_main" {
  for_each = local.pipelines

  rule     = aws_cloudwatch_event_rule.push_to_main[each.key].name
  arn      = aws_codepipeline.this[each.key].arn
  role_arn = aws_iam_role.events.arn
}
