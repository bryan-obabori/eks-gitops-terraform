# ============================================================
# DATA SOURCES
# ============================================================

data "aws_availability_zones" "available" {
  state = "available"
}


# ============================================================
# LOCAL VALUES
# ============================================================

locals {
  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    2
  )
}


# ============================================================
# VPC
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}


# ============================================================
# INTERNET GATEWAY
# ============================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}


# ============================================================
# PUBLIC SUBNETS
# ============================================================

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.availability_zones[0]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-a"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = local.availability_zones[1]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-b"
    "kubernetes.io/role/elb" = "1"
  }
}


# ============================================================
# PRIVATE SUBNETS
# ============================================================

resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.11.0/24"
  availability_zone       = local.availability_zones[0]
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.cluster_name}-private-a"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.12.0/24"
  availability_zone       = local.availability_zones[1]
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.cluster_name}-private-b"
    "kubernetes.io/role/internal-elb" = "1"
  }
}


# ============================================================
# ELASTIC IPS FOR NAT GATEWAYS
# ============================================================

resource "aws_eip" "nat_a" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-a-eip"
  }
}

resource "aws_eip" "nat_b" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-b-eip"
  }
}


# ============================================================
# NAT GATEWAYS
# ============================================================

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${var.cluster_name}-nat-a"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id

  tags = {
    Name = "${var.cluster_name}-nat-b"
  }

  depends_on = [aws_internet_gateway.main]
}


# ============================================================
# PUBLIC ROUTE TABLE
# ============================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}


# ============================================================
# PRIVATE ROUTE TABLE A
# ============================================================

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }

  tags = {
    Name = "${var.cluster_name}-private-a-rt"
  }
}


# ============================================================
# PRIVATE ROUTE TABLE B
# ============================================================

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_b.id
  }

  tags = {
    Name = "${var.cluster_name}-private-b-rt"
  }
}


# ============================================================
# ROUTE TABLE ASSOCIATIONS
# ============================================================

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}


# ============================================================
# EKS
# ============================================================

# EKS resources will be added next.


# ============================================================
# EKS CLUSTER IAM ROLE
# ============================================================

# EKS assumes this IAM role so the control plane can interact
# with AWS resources on our behalf.
resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "eks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Give the EKS control plane the AWS permissions it requires.
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}


# ============================================================
# EKS CLUSTER
# ============================================================

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.35"

  # Allow modern EKS API access while retaining ConfigMap
  # compatibility for Kubernetes authentication.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = [
      aws_subnet.private_a.id,
      aws_subnet.private_b.id
    ]

    endpoint_private_access = true
    endpoint_public_access  = true

    public_access_cidrs = [var.allowed_public_cidr]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = {
    Name = var.cluster_name
  }
}


# ============================================================
# EKS NODE IAM ROLE
# ============================================================

# EC2 worker nodes assume this role when they start.
resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}


# ============================================================
# EKS NODE IAM POLICIES
# ============================================================

# Allows worker nodes to communicate with EKS.
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

# Allows worker nodes to pull container images from Amazon ECR.
resource "aws_iam_role_policy_attachment" "eks_ecr_pull_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.eks_nodes.name
}

# Allows the Amazon VPC CNI plugin to manage networking for Pods.
#
# For this learning environment we attach it directly to the node role.
# In a more tightly separated production design, this permission can be
# moved to a dedicated role for the VPC CNI service account.
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}


# ============================================================
# EKS MANAGED NODE GROUP
# ============================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  # Worker nodes live only in private subnets.
  subnet_ids = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_ecr_pull_policy,
    aws_iam_role_policy_attachment.eks_cni_policy
  ]

  tags = {
    Name = "${var.cluster_name}-nodes"
  }
}