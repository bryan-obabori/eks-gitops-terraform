output "aws_region" {
  description = "AWS region used for this infrastructure"
  value       = var.aws_region
}

output "cluster_name" {
  description = "Name assigned to the EKS cluster"
  value       = var.cluster_name
}

output "vpc_id" {
  description = "ID of the VPC created for the EKS environment"
  value       = aws_vpc.main.id
}

output "availability_zones" {
  description = "Availability Zones selected for the EKS environment"
  value       = local.availability_zones
}