variable "aws_region" {
  description = "AWS region containing the EKS cluster"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster"
  type        = string
  default     = "go-web-app-cluster"
}