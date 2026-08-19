terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.55"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
  }
}