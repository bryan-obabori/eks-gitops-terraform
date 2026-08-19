# ============================================================
# AWS PROVIDER
# ============================================================

provider "aws" {
  region = var.aws_region
}


# ============================================================
# EXISTING EKS CLUSTER
# ============================================================

# Read information about the EKS cluster Terraform already created
# in the infra layer.
data "aws_eks_cluster" "main" {
  name = var.cluster_name
}

# Generate a temporary authentication token for the EKS cluster.
data "aws_eks_cluster_auth" "main" {
  name = var.cluster_name
}


# ============================================================
# KUBERNETES PROVIDER
# ============================================================

provider "kubernetes" {
  host = data.aws_eks_cluster.main.endpoint

  cluster_ca_certificate = base64decode(
    data.aws_eks_cluster.main.certificate_authority[0].data
  )

  token = data.aws_eks_cluster_auth.main.token
}


# ============================================================
# HELM PROVIDER
# ============================================================

provider "helm" {
  kubernetes = {
    host = data.aws_eks_cluster.main.endpoint

    cluster_ca_certificate = base64decode(
      data.aws_eks_cluster.main.certificate_authority[0].data
    )

    token = data.aws_eks_cluster_auth.main.token
  }
}