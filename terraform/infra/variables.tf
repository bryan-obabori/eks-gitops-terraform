variable "aws_region" {
  description = "AWS region where the infrastructure will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "go-web-app-cluster"
}

variable "environment" {
  description = "Environment name used for tagging resources"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Name used to identify resources belonging to this project"
  type        = string
  default     = "eks-gitops-terraform"
}

variable "vpc_cidr" {
  description = "CIDR block assigned to the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_public_cidr" {
  description = "CIDR allowed to access the EKS public API endpoint"
  type        = string
}
