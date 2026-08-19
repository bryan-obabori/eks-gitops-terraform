# Terraform EKS GitOps Platform

Production-style AWS EKS platform built with Terraform and deployed through GitOps.

This project provisions the AWS network and EKS cluster explicitly with Terraform, installs the platform components with Terraform, and uses Terraform to bootstrap the Argo CD `Application`. Argo CD then owns continuous application delivery from Git.

Project 1, which provided the reusable Go application and Helm assets, is public at [bryan-obabori/go-web-app-devops](https://github.com/bryan-obabori/go-web-app-devops).

## Architecture

```text
Terraform
│
├── terraform/infra
│   ├── VPC / subnets / routing
│   ├── Internet Gateway / NAT Gateways
│   ├── IAM
│   ├── EKS control plane
│   └── private managed node group
│
├── terraform/platform
│   ├── Argo CD
│   ├── EKS Pod Identity Agent
│   ├── AWS Load Balancer Controller
│   └── controller IAM / Pod Identity
│
└── terraform/apps
    └── Argo CD Application: go-web-app
            │
            v
         Argo CD
            │
            ├── Deployment
            ├── ClusterIP Service
            └── ALB Ingress
                    │
                    v
          AWS Load Balancer Controller
                    │
                    v
       Internet-facing Application Load Balancer
                    │
                    v
               Go web app
```

The ownership boundary is intentional: Terraform owns the AWS infrastructure, platform installation, and Argo CD bootstrap object. Argo CD owns the Kubernetes application resources. The AWS Load Balancer Controller creates and manages the ALB from the Kubernetes Ingress.

## What This Project Builds

### Infrastructure — `terraform/infra`

- VPC `10.0.0.0/16`
- Two public subnets across two Availability Zones
- Two private subnets across two Availability Zones
- Internet Gateway
- One NAT Gateway per Availability Zone
- Public and private route tables
- EKS control plane
- Managed node group with two private `t3.medium` workers
- EKS and node IAM roles/policies
- Restricted public EKS API access through a local `terraform.tfvars`

The worker nodes run only in private subnets and do not receive public IP addresses.

### Platform — `terraform/platform`

- Argo CD installed through Helm
- EKS Pod Identity Agent
- AWS Load Balancer Controller installed through Helm
- Dedicated IAM policy and role for the controller
- EKS Pod Identity association for `aws-load-balancer-controller`

The controller receives AWS permissions through Pod Identity rather than broad permissions on the worker-node role.

### Application bootstrap — `terraform/apps`

Terraform manages the Argo CD `Application` custom resource using `kubernetes_manifest`.

The Application points Argo CD at:

```text
gitops/go-web-app-chart
```

and enables:

```text
automated sync
prune
self-heal
```

The Application includes the Argo CD resource finalizer so destroying the Terraform apps layer cascades through the Argo-managed workload before the platform and cluster are removed.

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
│   │   ├── .terraform.lock.hcl
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── platform/
│   │   ├── .terraform.lock.hcl
│   │   ├── main.tf
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   └── apps/
│       ├── .terraform.lock.hcl
│       ├── main.tf
│       ├── providers.tf
│       ├── variables.tf
│       └── versions.tf
├── .gitignore
├── JOURNAL.md
└── README.md
```

## Prerequisites

- AWS CLI authenticated to the target AWS account
- Terraform
- `kubectl`
- Helm
- Git

AWS region and EKS cluster defaults are currently:

```text
Region:  us-east-1
Cluster: go-web-app-cluster
```

## Configure the Local EKS API CIDR

`terraform.tfvars` is intentionally ignored by Git because it contains an environment-specific public IP.

Create or update:

```text
terraform/infra/terraform.tfvars
```

with:

```hcl
allowed_public_cidr = "YOUR_CURRENT_PUBLIC_IP/32"
```

For example, you can discover your current public address and then write the `/32` value manually.

If your public IP changes while the cluster is already running, update this variable through the infrastructure layer before relying on Kubernetes-provider operations from the new address.

# Start / Rebuild the Environment

The order matters because each Terraform root module depends on the layer before it.

```text
infra
  ↓
EKS kubeconfig
  ↓
platform
  ↓
apps
  ↓
Argo CD reconciles workload
  ↓
ALB becomes available
```

### 1. Build the AWS/EKS infrastructure

```bash
terraform -chdir=terraform/infra init
terraform -chdir=terraform/infra fmt -check
terraform -chdir=terraform/infra validate
terraform -chdir=terraform/infra plan -out=tfplan
terraform -chdir=terraform/infra apply tfplan
```

### 2. Refresh kubeconfig

```bash
aws eks update-kubeconfig \
  --name go-web-app-cluster \
  --region us-east-1

kubectl get nodes -o wide
```

### 3. Build the platform layer

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform fmt -check
terraform -chdir=terraform/platform validate
terraform -chdir=terraform/platform plan -out=tfplan
terraform -chdir=terraform/platform apply tfplan
```

This installs Argo CD, the Pod Identity Agent, and AWS Load Balancer Controller before Terraform attempts to create the Argo `Application` custom resource.

### 4. Bootstrap the GitOps application with Terraform

```bash
terraform -chdir=terraform/apps init
terraform -chdir=terraform/apps fmt -check
terraform -chdir=terraform/apps validate
terraform -chdir=terraform/apps plan -out=tfplan
terraform -chdir=terraform/apps apply tfplan
```

There is no normal `kubectl apply -f argocd/application.yaml` step. Terraform owns that object.

### 5. Verify the running environment

```bash
kubectl get application go-web-app -n argocd
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default
```

Expected Argo state:

```text
SYNC STATUS   HEALTH STATUS
Synced        Healthy
```

Retrieve and test the ALB:

```bash
ALB=$(kubectl get ingress go-web-app \
  -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "$ALB"
curl -I "http://$ALB/home"
```

A healthy deployment returns:

```text
HTTP/1.1 200 OK
```

The ALB health check uses `/home` because the Go application intentionally has no `/` handler.

# Destroy the Environment

Destroy in the **reverse ownership order**.

```text
terraform/apps destroy
        ↓
Argo Application deleted
        ↓
Argo CD removes Deployment / Service / Ingress
        ↓
AWS Load Balancer Controller removes ALB
        ↓
terraform/platform destroy
        ↓
terraform/infra destroy
```

Do **not** destroy `terraform/infra` first. The EKS cluster and controllers need to remain alive long enough to clean up the Argo-managed Ingress and AWS ALB.

### 1. Destroy the Terraform apps layer

```bash
terraform -chdir=terraform/apps init
terraform -chdir=terraform/apps plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/apps apply destroy.tfplan
```

Because the Argo `Application` has the cascading resource finalizer, this removal should delete the application resources managed by Argo CD.

Verify the application and Ingress are gone before continuing:

```bash
kubectl get application go-web-app -n argocd 2>/dev/null || true
kubectl get deployment,svc,ingress -n default
```

The built-in `service/kubernetes` is expected to remain.

Also confirm there is no application ALB left before removing the controller:

```bash
kubectl get ingress -A
```

### 2. Destroy the platform layer

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/platform apply destroy.tfplan
```

This removes Argo CD, AWS Load Balancer Controller, Pod Identity resources, controller IAM resources, and the Pod Identity Agent add-on.

### 3. Destroy the infrastructure layer

The required local `terraform/infra/terraform.tfvars` must still exist so Terraform can load the infrastructure configuration.

```bash
terraform -chdir=terraform/infra init
terraform -chdir=terraform/infra plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/infra apply destroy.tfplan
```

Terraform then removes the managed node group, EKS control plane, NAT Gateways, Elastic IPs, routing, subnets, Internet Gateway, IAM resources, and VPC according to its dependency graph.

### 4. Quick post-destroy checks

```bash
aws eks list-clusters \
  --region us-east-1 \
  --query "clusters[?@=='go-web-app-cluster']"

terraform -chdir=terraform/apps state list
terraform -chdir=terraform/platform state list
terraform -chdir=terraform/infra state list
```

For a complete destroy, the cluster query should return `[]` and each Terraform state should contain no managed resources.

Do not manually delete unrelated NAT Gateways, EIPs, volumes, load balancers, or other account resources just because they exist. Terraform should remain the lifecycle owner of resources created by this project.

## GitOps Workflow

Application source changes follow this path:

```text
Project 1 application source change
        ↓
GitHub Actions builds a Docker image
        ↓
GitOps image tag is updated
        ↓
Argo CD detects the Git change
        ↓
Helm chart is rendered
        ↓
Kubernetes Deployment rolls out the image
```

The Kubernetes Service remains `ClusterIP`. The AWS Load Balancer Controller uses ALB `target-type: ip`, allowing the ALB to register pod IPs without exposing the worker nodes directly.

## Design Decisions

**Three Terraform lifecycle layers** — `infra`, `platform`, and `apps` are separate root modules and states because they have different dependencies and lifecycles.

**Terraform owns the bootstrap boundary** — Terraform creates the Argo CD `Application`; no manual `kubectl apply` is required during a normal rebuild.

**Argo CD owns workload reconciliation** — Terraform does not also manage the Deployment, Service, and Ingress. Avoiding dual ownership prevents Terraform and Argo CD from fighting over the same resources.

**Private worker nodes** — workloads run without public node IP addresses.

**Two Availability Zones** — the network and workers span two AZs.

**One NAT Gateway per AZ** — costs more than a single-NAT lab, but demonstrates AZ-independent egress design.

**EKS Pod Identity** — AWS Load Balancer Controller receives a dedicated AWS identity rather than inheriting broad worker-node permissions.

**Argo CD automated sync** — desired application state lives in Git and is continuously reconciled.

## Terraform State and Secrets

Terraform state is local for this lab and excluded from Git through `.gitignore`.

`*.tfvars` files are also ignored so environment-specific values such as the administrator public CIDR are not committed.

Because state is local, the start/destroy lifecycle above assumes the same checkout and Terraform state files are available. For a shared, long-lived, or recoverable environment, the next infrastructure improvement would be a remote Terraform backend with locking and controlled access.

Provider lock files (`.terraform.lock.hcl`) are committed intentionally.

## Cost Warning

The running environment includes billable resources such as:

- EKS control plane
- two EC2 worker nodes
- two NAT Gateways
- NAT Gateway Elastic IPs
- Application Load Balancer

Destroy the environment when the lab is no longer needed using the reverse Terraform order documented above.

## Key Troubleshooting Lessons

- An ALB DNS lookup can fail temporarily while the load balancer is still provisioning; verify AWS state before changing infrastructure.
- An HTTP `404` from the Go application proved the ALB-to-pod path was functioning; the requested route `/` simply did not exist.
- `/home` returned HTTP `200`, so the ALB health-check path was changed to `/home`.
- Environment-specific public IP values belong in ignored Terraform variables, not public Git.
- Higher-level tools can hide important infrastructure relationships; explicitly building EKS with Terraform made subnetting, routing, IAM, Pod Identity, and load-balancer dependencies visible.

## Outcome

This project demonstrates a complete Terraform-to-GitOps ownership chain:

```text
Terraform
+ AWS networking
+ EKS
+ IAM / Pod Identity
+ Helm
+ Argo CD
+ Terraform-managed Argo Application
+ GitOps
+ Kubernetes
+ AWS Load Balancer Controller
+ Application Load Balancer
```

The environment can be rebuilt from source and destroyed through the same three Terraform lifecycle layers, with Argo CD retaining ownership of the application resources beneath the bootstrap boundary.
