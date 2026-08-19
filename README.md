# Terraform EKS GitOps Platform

Production-style AWS EKS platform built with Terraform and deployed through GitOps.

This project provisions the AWS network and EKS cluster explicitly with Terraform, installs the platform components separately, and uses Argo CD to continuously deploy a Helm-packaged Go web application from GitHub.

## Architecture

```text
GitHub
  |
  | Argo CD watches main
  v
Argo CD
  |
  | renders Helm chart
  v
Kubernetes Deployment + Service + Ingress
  |
  v
AWS Load Balancer Controller
  |
  v
Internet-facing Application Load Balancer
  |
  v
Go web application

AWS infrastructure

Internet Gateway
      |
      v
Public subnets in two AZs
  |                 |
NAT Gateway A    NAT Gateway B
  |                 |
  v                 v
Private subnet A  Private subnet B
      |                 |
      +-------+---------+
              |
              v
        EKS managed nodes
```

## What This Project Builds

### Infrastructure layer — `terraform/infra`

- VPC with CIDR `10.0.0.0/16`
- Two public subnets across two Availability Zones
- Two private subnets across two Availability Zones
- Internet Gateway
- One NAT Gateway per Availability Zone
- Public and private route tables
- EKS control plane
- Managed EKS node group with two private worker nodes
- IAM roles and policies required by EKS and the node group
- Restricted public EKS API access through a local `terraform.tfvars` value

The worker nodes run only in private subnets and do not receive public IP addresses.

### Platform layer — `terraform/platform`

- Argo CD installed with Helm
- EKS Pod Identity Agent
- AWS Load Balancer Controller
- Dedicated IAM policy and role for the controller
- EKS Pod Identity association for the controller service account

The AWS Load Balancer Controller uses Pod Identity instead of broad permissions on the worker-node role.

### GitOps layer

Argo CD watches this repository:

```text
gitops/go-web-app-chart
```

The Argo CD `Application` uses automated synchronization with pruning and self-healing enabled.

```text
Git commit
    |
    v
Argo CD reconciliation
    |
    v
Helm render
    |
    v
Kubernetes Deployment / Service / Ingress
```

## Repository Structure

```text
eks-gitops-terraform/
├── argocd/
│   └── application.yaml
├── gitops/
│   └── go-web-app-chart/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── ingress.yaml
│           └── service.yaml
├── terraform/
│   ├── infra/
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   └── platform/
│       ├── main.tf
│       ├── providers.tf
│       ├── variables.tf
│       └── versions.tf
├── .gitignore
├── README.md
└── TEARDOWN.md
```

## Prerequisites

- AWS CLI authenticated to an AWS account
- Terraform
- `kubectl`
- Helm
- Git
- Access to the GitHub repository

## Deploy

### 1. Configure the allowed EKS API CIDR

`terraform.tfvars` is intentionally ignored by Git.

Create:

```text
terraform/infra/terraform.tfvars
```

with:

```hcl
allowed_public_cidr = "YOUR_PUBLIC_IP/32"
```

### 2. Provision AWS infrastructure

```bash
terraform -chdir=terraform/infra init
terraform -chdir=terraform/infra fmt
terraform -chdir=terraform/infra validate
terraform -chdir=terraform/infra plan -out=tfplan
terraform -chdir=terraform/infra apply tfplan
```

### 3. Configure kubectl

```bash
aws eks update-kubeconfig \
  --name go-web-app-cluster \
  --region us-east-1

kubectl get nodes -o wide
```

### 4. Install platform components

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform fmt
terraform -chdir=terraform/platform validate
terraform -chdir=terraform/platform plan -out=tfplan
terraform -chdir=terraform/platform apply tfplan
```

Verify Argo CD and the AWS Load Balancer Controller:

```bash
kubectl get pods -n argocd
kubectl get pods -n kube-system
```

### 5. Bootstrap the GitOps application

```bash
kubectl apply -f argocd/application.yaml
```

Verify:

```bash
kubectl get application go-web-app -n argocd
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default
```

Expected Argo CD state:

```text
SYNC STATUS   HEALTH STATUS
Synced        Healthy
```

## Application Access

Retrieve the ALB hostname:

```bash
ALB=$(kubectl get ingress go-web-app \
  -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "$ALB"
```

The application exposes `/home` as its home page:

```bash
curl -I "http://$ALB/home"
```

A healthy deployment returns:

```text
HTTP/1.1 200 OK
```

The ALB health check is configured to use `/home` because the application does not define a handler for `/`.

## GitOps Workflow

Application changes are delivered without manually applying Kubernetes manifests:

```text
Application source change
        |
        v
CI builds a new Docker image
        |
        v
GitOps image tag is updated
        |
        v
Argo CD detects Git change
        |
        v
Deployment rolls out new image
```

The Kubernetes Service remains `ClusterIP`. The AWS Load Balancer Controller uses ALB IP target mode to register pod IP addresses as load-balancer targets.

## Design Decisions

**Private worker nodes** — application workloads run without public node IP addresses.

**Two Availability Zones** — the network and worker nodes span two AZs.

**One NAT Gateway per AZ** — improves AZ independence compared with routing all private subnets through one NAT Gateway.

**Separate Terraform root modules** — `infra` manages the long-lived AWS/EKS foundation while `platform` manages Kubernetes-facing platform components. Each directory therefore has its own Terraform state.

**EKS Pod Identity** — the AWS Load Balancer Controller receives AWS permissions through a dedicated pod identity rather than inheriting broad worker-node permissions.

**Argo CD automated sync** — application desired state lives in Git and Argo CD continuously reconciles the cluster to that state.

## Verification Commands

```bash
echo "===== NODES ====="
kubectl get nodes -o wide

echo "===== ARGO ====="
kubectl get application go-web-app -n argocd

echo "===== APP ====="
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default

echo "===== CONTROLLER ====="
kubectl get pods -n kube-system | grep -E 'aws-load-balancer-controller|eks-pod-identity-agent'

echo "===== LIVE APP ====="
ALB=$(kubectl get ingress go-web-app -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -I "http://$ALB/home"
```

## State and Secrets

Terraform state is local for this lab and is excluded from Git through `.gitignore`.

`*.tfvars` files are also ignored so account-specific values such as the administrator's public CIDR are not committed.

For a shared or long-lived environment, the next step would be migrating state to a remote backend with locking and controlled access.

## Cost Warning

This lab creates billable AWS resources, including:

- EKS control plane
- EC2 worker nodes
- NAT Gateways
- Application Load Balancer
- Elastic IP addresses associated with the NAT Gateways

Destroy the environment when it is no longer needed. Follow [TEARDOWN.md](TEARDOWN.md) rather than deleting resources manually or in an arbitrary order.

## Teardown

See [TEARDOWN.md](TEARDOWN.md) for the complete cleanup sequence.

The high-level order is:

```text
Argo CD Application
        |
        v
Application resources / ALB
        |
        v
Terraform platform layer
        |
        v
Terraform infrastructure layer
        |
        v
AWS orphan-resource verification
```

## Outcome

This project demonstrates an end-to-end EKS platform lifecycle with:

```text
Terraform
+ AWS networking
+ EKS
+ IAM / Pod Identity
+ Helm
+ AWS Load Balancer Controller
+ Argo CD
+ GitOps
+ Kubernetes
+ Application Load Balancer
```

The environment is reproducible from infrastructure provisioning through application deployment and can be removed through the documented Terraform teardown process.
