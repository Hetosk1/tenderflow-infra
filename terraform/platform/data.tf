# Managed data stores: DocumentDB (MongoDB-compatible) + ElastiCache (Valkey).
# Destroyed with the rest of the platform stack - data does NOT survive `terraform destroy`.
#
# Connection strings and the JWT secret are written to SSM Parameter Store under
# /tenderflow/*, which External Secrets (addons.tf) syncs into Kubernetes Secrets.

# Pods use the node's network (VPC CNI), so allow the private subnets the nodes live in
locals {
  app_cidrs = module.vpc.private_subnets_cidr_blocks
}

# ---------------------------------------------------------------------------
# DocumentDB
# ---------------------------------------------------------------------------
resource "random_password" "docdb" {
  length  = 32
  special = false # DocumentDB rejects / " @ and the password goes into a URI
}

resource "aws_security_group" "docdb" {
  name        = "${local.name}-docdb"
  description = "DocumentDB: MongoDB port from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = local.app_cidrs
  }
}

resource "aws_docdb_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_docdb_cluster_parameter_group" "this" {
  name   = "${local.name}-docdb8"
  family = "docdb8.0"

  parameter {
    name  = "tls"
    value = "enabled"
  }
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier              = local.name
  engine                          = "docdb"
  engine_version                  = "8.0.0"
  master_username                 = "tenderflow"
  master_password                 = random_password.docdb.result
  db_subnet_group_name            = aws_docdb_subnet_group.this.name
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.this.name
  vpc_security_group_ids          = [aws_security_group.docdb.id]

  storage_encrypted       = true
  backup_retention_period = 1

  # Destroyable stack: no final snapshot, no deletion protection
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true
}

resource "aws_docdb_cluster_instance" "this" {
  identifier         = "${local.name}-1"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.docdb_instance_class
  apply_immediately  = true
}

# ---------------------------------------------------------------------------
# ElastiCache (Valkey: Redis-compatible, works with the `redis` npm client)
# ---------------------------------------------------------------------------
resource "aws_security_group" "cache" {
  name        = "${local.name}-cache"
  description = "ElastiCache: Valkey port from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = local.app_cidrs
  }
}

resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "TenderFlow cache"
  engine               = "valkey"
  engine_version       = "9.1"
  node_type            = var.cache_node_type
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true # clients must use rediss://
  automatic_failover_enabled = false
  apply_immediately          = true
}

# ---------------------------------------------------------------------------
# App config in SSM, synced into the cluster by External Secrets
# ---------------------------------------------------------------------------
resource "random_password" "jwt" {
  length  = 64
  special = false
}

locals {
  # tlsCAFile path is baked into each service image (see the service Dockerfiles).
  # authMechanism=SCRAM-SHA-1: mongodb driver 7.x defaults to SCRAM-SHA-256, which
  # DocumentDB rejects with "Unsupported mechanism [ -301 ]".
  mongo_uri = format(
    "mongodb://%s:%s@%s:%d/tenderflow?tls=true&tlsCAFile=/app/certs/global-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false&authMechanism=SCRAM-SHA-1",
    aws_docdb_cluster.this.master_username,
    random_password.docdb.result,
    aws_docdb_cluster.this.endpoint,
    aws_docdb_cluster.this.port,
  )

  redis_uri = "rediss://${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
}

resource "aws_ssm_parameter" "mongo_uri" {
  name  = "/tenderflow/mongo-uri"
  type  = "SecureString"
  value = local.mongo_uri
}

resource "aws_ssm_parameter" "redis_uri" {
  name  = "/tenderflow/redis-uri"
  type  = "SecureString"
  value = local.redis_uri
}

resource "aws_ssm_parameter" "jwt_secret" {
  name  = "/tenderflow/jwt-secret"
  type  = "SecureString"
  value = random_password.jwt.result
}
