# ---------------------------------------------------------------------------
# Infrastructure for serving an LLM on EKS.
#
# The VPC / EKS / Karpenter / IRSA modules are CONSUMED FROM ANOTHER REPO at a
# pinned tag rather than copy-pasted here. That is deliberate: it is how
# multi-repo Terraform actually works in a team — modules are versioned
# artifacts, and a consumer pins a ref so upstream changes never surprise it.
#   source repo: https://github.com/VJK94/AI-ML-ops  (eks-platform/modules)
# ---------------------------------------------------------------------------

# Note: module `source` cannot be interpolated — no variables, no locals, not
# even for the ref. Terraform resolves sources before evaluating anything
# else. So the repo URL and tag are repeated literally on every module below;
# bumping the version means editing each one (or using Terragrunt, which
# exists partly for this).

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "vllm-on-eks"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "git::https://github.com/VJK94/AI-ML-ops.git//eks-platform/modules/vpc?ref=week-06"

  name               = var.name
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = true # demo: one NAT. Production: one per AZ.
  cluster_name       = var.name
}

module "eks" {
  source = "git::https://github.com/VJK94/AI-ML-ops.git//eks-platform/modules/eks?ref=week-06"

  cluster_name    = var.name
  cluster_version = var.cluster_version
  subnet_ids      = module.vpc.private_subnet_ids

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Small CPU group for the control-plane-adjacent workloads: Karpenter
  # itself, Prometheus, the LB controller, CoreDNS. GPU nodes come from
  # Karpenter, never from here.
  node_instance_types = var.system_instance_types
  node_capacity_type  = "SPOT"
  node_desired_size   = var.system_min_size
  node_min_size       = var.system_min_size
  node_max_size       = var.system_max_size
}

module "karpenter" {
  source = "git::https://github.com/VJK94/AI-ML-ops.git//eks-platform/modules/karpenter?ref=week-06"

  cluster_name              = module.eks.cluster_name
  cluster_arn               = module.eks.cluster_arn
  cluster_security_group_id = module.eks.cluster_security_group_id
  oidc_provider_arn         = module.eks.oidc_provider_arn
  oidc_issuer_url           = module.eks.oidc_issuer_url
}

module "lb_controller_irsa" {
  source = "git::https://github.com/VJK94/AI-ML-ops.git//eks-platform/modules/irsa?ref=week-06"

  role_name          = "${var.name}-lb-controller"
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_issuer_url    = module.eks.oidc_issuer_url
  namespace          = "kube-system"
  service_account    = "aws-load-balancer-controller"
  attach_policy_json = true
  policy_json        = file("${path.module}/policies/aws-load-balancer-controller-iam.json")
}

# ---------------------------------------------------------------------------
# Model weights in S3 (phase 2 of the cold-start work — see docs/cold-start.md)
#
# Phase 1 lets vLLM pull from huggingface.co at pod start, which makes the
# problem measurable. Phase 2 seeds this bucket once and has an init container
# copy from it: faster, and it removes a third-party dependency from the
# startup path of every replica.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "weights" {
  count = var.create_weights_bucket ? 1 : 0

  bucket        = "${var.name}-weights-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

module "weights_reader_irsa" {
  count  = var.create_weights_bucket ? 1 : 0
  source = "git::https://github.com/VJK94/AI-ML-ops.git//eks-platform/modules/irsa?ref=week-06"

  role_name          = "${var.name}-weights-reader"
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_issuer_url    = module.eks.oidc_issuer_url
  namespace          = "inference"
  service_account    = "vllm"
  attach_policy_json = true

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.weights[0].arn
      },
      {
        # Write too, so the one-off seeding Job can populate the bucket
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.weights[0].arn}/*"
      }
    ]
  })
}
