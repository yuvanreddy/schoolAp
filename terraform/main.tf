# ──────────────────────────────────────────────
# EduSphere — Terraform Infrastructure (AWS)
# Region: ap-south-1 (Mumbai)
# ──────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }

  backend "s3" {
    # Real values — confirmed setup on 31 Mar 2026
    bucket         = "edusphere-tf-state-816069153839"
    dynamodb_table = "edusphere-tf-locks"
    region         = "ap-south-1"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "EduSphere"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Team        = "EduSphere-SRE"
      Domain      = "workforschool.com"
      AccountID   = "816069153839"
    }
  }
}

# ── Variables ──────────────────────────────────
variable "aws_region"     { default = "ap-south-1" }
variable "environment"    { default = "staging" }
variable "app_image_tag"  { default = "latest" }
variable "db_password"    { sensitive = true }

locals {
  cluster_name = "edusphere-eks"
  vpc_cidr     = "10.0.0.0/16"
}

# ── VPC ────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.7.0"

  name = "edusphere-vpc-${var.environment}"
  cidr = local.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = var.environment != "production"
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

# ── ECR Repository ─────────────────────────────
resource "aws_ecr_repository" "school_app" {
  name                 = "edusphere-school-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "school_app" {
  repository = aws_ecr_repository.school_app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 production images"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["sha-"]
        countType     = "imageCountMoreThan"
        countNumber   = 20
      }
      action = { type = "expire" }
    }]
  })
}

# ── EKS Cluster ────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
  }

  eks_managed_node_groups = {
    app_nodes = {
      name           = "edu-app-ng"
      instance_types = var.environment == "production" ? ["t3.medium"] : ["t3.small"]
      min_size       = var.environment == "production" ? 2 : 1
      max_size       = var.environment == "production" ? 6 : 2
      desired_size   = var.environment == "production" ? 3 : 1

      labels = { role = "app" }
      taints = []

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }

    monitoring_nodes = {
      name           = "edu-mon-ng"
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      labels         = { role = "monitoring" }
      taints = [{
        key    = "monitoring"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  # IAM roles for EKS
  enable_cluster_creator_admin_permissions = true
}

# ── RDS (PostgreSQL) ───────────────────────────
resource "aws_db_subnet_group" "edusphere" {
  name       = "edusphere-db-subnet-${var.environment}"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name   = "edusphere-rds-sg-${var.environment}"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_db_instance" "edusphere" {
  identifier        = "edusphere-db-${var.environment}"
  engine            = "postgres"
  engine_version    = "16.13"
  instance_class    = var.environment == "production" ? "db.t3.small" : "db.t3.micro"
  allocated_storage = var.environment == "production" ? 50 : 20
  storage_encrypted = true

  db_name  = "edusphere"
  username = "edusphere_admin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.edusphere.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = var.environment == "production" ? 7 : 1
  skip_final_snapshot     = var.environment != "production"
  multi_az                = var.environment == "production"
  deletion_protection     = var.environment == "production"
}

# ── S3 for Static Assets ───────────────────────
resource "aws_s3_bucket" "assets" {
  bucket = "edusphere-assets-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

# ── CloudWatch Log Group ───────────────────────
resource "aws_cloudwatch_log_group" "edusphere" {
  name              = "/edusphere/${var.environment}"
  retention_in_days = 30
}

# ── Outputs ────────────────────────────────────
output "eks_endpoint"   { value = module.eks.cluster_endpoint }
output "rds_endpoint"   { value = aws_db_instance.edusphere.endpoint }
output "ecr_url"        { value = aws_ecr_repository.school_app.repository_url }
output "alb_dns_name"   { value = "Provisioned by ALB Ingress Controller" }
