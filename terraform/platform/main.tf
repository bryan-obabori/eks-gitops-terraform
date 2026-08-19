# ============================================================
# ARGO CD
# ============================================================

resource "helm_release" "argocd" {
  name = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.2.1"

  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
      }
    })
  ]
}


# ============================================================
# EKS POD IDENTITY AGENT
# ============================================================

# Pod Identity Agent runs on the EKS worker nodes and provides
# temporary AWS credentials to Pods that have Pod Identity
# associations.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = var.cluster_name
  addon_name   = "eks-pod-identity-agent"
}


# ============================================================
# AWS LOAD BALANCER CONTROLLER IAM POLICY
# ============================================================

# Download the official IAM policy for the exact controller
# version we are installing.
data "http" "aws_lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.4.3/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_lbc" {
  name        = "${var.cluster_name}-aws-load-balancer-controller"
  description = "IAM permissions for the AWS Load Balancer Controller"

  policy = data.http.aws_lbc_iam_policy.response_body
}


# ============================================================
# AWS LOAD BALANCER CONTROLLER IAM ROLE
# ============================================================

# This role can only be assumed through EKS Pod Identity by
# the aws-load-balancer-controller service account in kube-system.
resource "aws_iam_role" "aws_lbc" {
  name = "${var.cluster_name}-aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowEksPodIdentity"
        Effect = "Allow"

        Principal = {
          Service = "pods.eks.amazonaws.com"
        }

        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]

        Condition = {
          StringEquals = {
            "aws:RequestTag/eks-cluster-arn"            = data.aws_eks_cluster.main.arn
            "aws:RequestTag/kubernetes-namespace"       = "kube-system"
            "aws:RequestTag/kubernetes-service-account" = "aws-load-balancer-controller"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "aws_lbc" {
  role       = aws_iam_role.aws_lbc.name
  policy_arn = aws_iam_policy.aws_lbc.arn
}


# ============================================================
# AWS LOAD BALANCER CONTROLLER SERVICE ACCOUNT
# ============================================================

resource "kubernetes_service_account_v1" "aws_lbc" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
  }
}


# ============================================================
# EKS POD IDENTITY ASSOCIATION
# ============================================================

resource "aws_eks_pod_identity_association" "aws_lbc" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = kubernetes_service_account_v1.aws_lbc.metadata[0].name
  role_arn        = aws_iam_role.aws_lbc.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.aws_lbc
  ]
}


# ============================================================
# AWS LOAD BALANCER CONTROLLER
# ============================================================

resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.4.3"

  namespace = "kube-system"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.aws_region
      vpcId       = data.aws_eks_cluster.main.vpc_config[0].vpc_id

      serviceAccount = {
        create = false
        name   = kubernetes_service_account_v1.aws_lbc.metadata[0].name
      }
    })
  ]

  depends_on = [
    aws_eks_pod_identity_association.aws_lbc
  ]
}