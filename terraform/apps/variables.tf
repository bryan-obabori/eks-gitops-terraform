variable "aws_region" {
  description = "AWS region containing the EKS cluster"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster managed by the infrastructure layer"
  type        = string
  default     = "go-web-app-cluster"
}
