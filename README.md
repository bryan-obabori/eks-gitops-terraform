# Terraform EKS GitOps Platform

A self-contained DevOps project that builds a Go web application, publishes an immutable container image, provisions a production-style AWS EKS platform with Terraform, and continuously deploys the application through Argo CD and GitOps.

Project 2 is an improved evolution of Project 1. The earlier project proved the basic Docker, Kubernetes, Helm, GitHub Actions, Argo CD, and EKS delivery flow. Project 2 rebuilds the same application-delivery idea with explicit Terraform-managed AWS infrastructure, private worker nodes, EKS Pod Identity, AWS Load Balancer Controller, Terraform-managed Argo bootstrap, and a repository-local CI pipeline.

## End-to-End Architecture

```text
Developer changes app/
        |
        v
GitHub Actions
  - go test
  - go build
  - Docker build
        |
        v
Docker Hub
bryanobabori/go-web-app:run-<GITHUB_RUN_ID>
        |
        +------------------------------+
                                       |
GitHub Actions updates                 |
gitops/go-web-app-chart/values.yaml    |
        |                              |
        v                              |
Git commit                             |
        |                              |
        v                              |
Argo CD -------------------------------+
        |
        v
Helm Deployment / Service / Ingress
        |
        v
AWS Load Balancer Controller
        |
        v
Internet-facing ALB
        |
        v
Go web application
```

The platform underneath that delivery flow is provisioned by Terraform:

```text
Terraform
|
├── terraform/infra
│   ├── VPC / subnets / routing
│   ├── Internet Gateway / NAT Gateways
│   ├── IAM
│   ├── EKS control plane
│   └── private managed node group
|
├── terraform/platform
│   ├── Argo CD
│   ├── EKS Pod Identity Agent
│   ├── AWS Load Balancer Controller
│   └── controller IAM / Pod Identity
|
└── terraform/apps
    └── Argo CD Application: go-web-app
```

## Ownership Model

The ownership boundaries are intentional:

- **Application source and CI:** this repository
- **Container artifact:** Docker Hub
- **AWS infrastructure:** Terraform `infra`
- **Platform components:** Terraform `platform`
- **Argo CD bootstrap object:** Terraform `apps`
- **Deployment, Service, and Ingress:** Argo CD
- **AWS ALB generated from Ingress:** AWS Load Balancer Controller

Terraform does not manage the same Kubernetes workload resources that Argo CD manages. This avoids dual ownership.

## Repository Structure

```text
eks-gitops-terraform/
├── app/
│   ├── Dockerfile
│   ├── go.mod
│   ├── main.go
│   ├── main_test.go
│   └── static/
│       ├── about.html
│       ├── contact.html
│       ├── courses.html
│       ├── home.html
│       └── images/
│
├── .github/
│   └── workflows/
│       └── ci.yaml
│
├── argocd/
│   └── application.yaml
│
├── gitops/
│   └── go-web-app-chart/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── ingress.yaml
│           └── service.yaml
│
├── terraform/
│   ├── infra/
│   ├── platform/
│   └── apps/
│
├── .gitignore
├── ABOUT.md
├── JOURNAL.md
└── README.md
```

## Application

The Go application lives in `app/` and exposes:

```text
/home
/courses
/about
/contact
```

It intentionally has no `/` route, so the ALB health check uses `/home`.

The Dockerfile uses a multi-stage build and produces a small distroless runtime image. Images are built explicitly for `linux/amd64`, matching the EKS worker-node architecture.

## Continuous Integration and GitOps Delivery

The workflow is defined at:

```text
.github/workflows/ci.yaml
```

It triggers when either the application or workflow changes:

```text
app/**
.github/workflows/ci.yaml
```

The pipeline performs:

```text
checkout
  ↓
setup Go using app/go.mod
  ↓
go test
  ↓
go build
  ↓
Docker Buildx
  ↓
Docker Hub login
  ↓
build + push linux/amd64 image
  ↓
update GitOps image tag
  ↓
commit values.yaml change
```

The image format is:

```text
bryanobabori/go-web-app:run-<GITHUB_RUN_ID>
```

Using immutable run-specific tags makes each deployment identifiable and avoids ambiguity from mutable tags such as `latest`.

The workflow then updates:

```text
gitops/go-web-app-chart/values.yaml
```

Argo CD watches that chart. When the GitOps commit changes the desired image tag, Argo CD reconciles the cluster and Kubernetes performs the rollout.

Because the workflow trigger is limited to `app/**` and the workflow file itself, the bot-generated commit that changes only `gitops/go-web-app-chart/values.yaml` does not create a CI loop.

### Required GitHub repository configuration

Repository variable:

```text
DOCKERHUB_USERNAME
```

Repository secret:

```text
DOCKERHUB_TOKEN
```

Credentials are never stored in the workflow file.

## Infrastructure — `terraform/infra`

The infrastructure layer provisions:

- VPC `10.0.0.0/16`
- two public subnets across two Availability Zones
- two private subnets across two Availability Zones
- Internet Gateway
- one NAT Gateway per Availability Zone
- public and private route tables
- EKS control plane
- managed node group with two private `t3.medium` workers
- EKS and node IAM roles/policies
- restricted public EKS API access through an ignored local `terraform.tfvars`

Worker nodes run only in private subnets and do not receive public IP addresses.

## Platform — `terraform/platform`

The platform layer installs and manages:

- Argo CD through Helm
- EKS Pod Identity Agent
- AWS Load Balancer Controller through Helm
- dedicated controller IAM policy and role
- EKS Pod Identity association for `aws-load-balancer-controller`

The controller receives AWS permissions through Pod Identity rather than broad permissions on the worker-node role.

## Application Bootstrap — `terraform/apps`

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

The Application also includes the Argo CD resource finalizer so workload cleanup can complete before platform and infrastructure teardown.

## Prerequisites

- AWS CLI authenticated to the target account
- Terraform
- kubectl
- Helm
- Git
- Docker, for local image testing
- Go, for local application testing

Current defaults:

```text
AWS region: us-east-1
EKS cluster: go-web-app-cluster
```

## Configure the Local EKS API CIDR

`terraform.tfvars` is intentionally ignored because it contains an environment-specific public IP.

Create:

```text
terraform/infra/terraform.tfvars
```

with:

```hcl
allowed_public_cidr = "YOUR_CURRENT_PUBLIC_IP/32"
```

If the administrator public IP changes while the cluster is running, update this variable through the infrastructure layer before relying on Kubernetes-provider operations from the new address.

# Build / Start the Environment

The order matters:

```text
infra
  ↓
EKS kubeconfig
  ↓
platform
  ↓
apps
  ↓
Argo CD reconciles GitOps workload
  ↓
ALB becomes available
```

### 1. Provision AWS and EKS

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

### 3. Provision platform components

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform fmt -check
terraform -chdir=terraform/platform validate
terraform -chdir=terraform/platform plan -out=tfplan
terraform -chdir=terraform/platform apply tfplan
```

### 4. Bootstrap the Argo CD Application

```bash
terraform -chdir=terraform/apps init
terraform -chdir=terraform/apps fmt -check
terraform -chdir=terraform/apps validate
terraform -chdir=terraform/apps plan -out=tfplan
terraform -chdir=terraform/apps apply tfplan
```

There is no normal `kubectl apply -f argocd/application.yaml` step. Terraform owns that bootstrap object.

### 5. Verify

```bash
kubectl get application go-web-app -n argocd
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default
```

Expected Argo state:

```text
Synced / Healthy
```

Test the ALB:

```bash
ALB=$(kubectl get ingress go-web-app \
  -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -I "http://$ALB/home"
```

Expected response:

```text
HTTP/1.1 200 OK
```

# Application Delivery

Once the platform exists, normal application delivery does **not** require Terraform.

Change files under `app/` and push to `main`:

```text
app change
  ↓
GitHub Actions
  ↓
new Docker image
  ↓
GitOps values update
  ↓
Argo CD sync
  ↓
Kubernetes rollout
```

Terraform is used when infrastructure, platform, or bootstrap configuration changes. GitHub Actions + Argo CD handle normal application releases.

# Destroy the Environment

Destroy in reverse ownership order:

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

Do not destroy infrastructure first. The EKS cluster and controllers need to remain available long enough to clean up the Argo-managed resources and ALB.

### 1. Destroy apps

```bash
terraform -chdir=terraform/apps init
terraform -chdir=terraform/apps plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/apps apply destroy.tfplan
```

Verify workload and Ingress cleanup before continuing:

```bash
kubectl get application go-web-app -n argocd 2>/dev/null || true
kubectl get deployment,svc,ingress -n default
kubectl get ingress -A
```

### 2. Destroy platform

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/platform apply destroy.tfplan
```

### 3. Destroy infrastructure

Keep the required local `terraform/infra/terraform.tfvars` available during the destroy operation.

```bash
terraform -chdir=terraform/infra init
terraform -chdir=terraform/infra plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/infra apply destroy.tfplan
```

## Key Design Decisions

**Self-contained repository** — Project 2 now owns its application source, CI, GitOps configuration, Terraform infrastructure, and Argo bootstrap. It no longer depends on Project 1 for application delivery.

**Three Terraform lifecycle layers** — infrastructure, platform components, and GitOps bootstrap have different dependencies and therefore separate Terraform roots/states.

**Terraform owns the bootstrap boundary** — Terraform creates the Argo CD Application; Argo CD owns the workload below that boundary.

**Immutable container tags** — GitHub Actions publishes `run-<GITHUB_RUN_ID>` rather than relying on `latest`.

**Private worker nodes** — workloads run without public node IPs.

**Two Availability Zones and two NAT Gateways** — the design demonstrates AZ-independent private egress, at higher lab cost than a single-NAT architecture.

**EKS Pod Identity** — AWS Load Balancer Controller receives a dedicated AWS identity rather than inheriting broad node permissions.

**ALB IP target mode** — the Service remains `ClusterIP`; the ALB registers pod IPs through the controller.

## Terraform State and Secrets

Terraform state remains local for this lab and is excluded from Git. `*.tfvars` files are also ignored so environment-specific values are not published.

Provider lock files (`.terraform.lock.hcl`) are committed intentionally.

For a shared or long-lived environment, a natural next improvement would be a remote Terraform backend with locking and controlled access.

## Cost Warning

Running the environment incurs charges for resources including:

- EKS control plane
- EC2 worker nodes
- NAT Gateways
- Elastic IPs associated with NAT
- Application Load Balancer

Destroy the environment when it is no longer needed.

## Key Troubleshooting Lessons

- ALB DNS may not resolve immediately while the load balancer is still provisioning.
- An HTTP `404` from `/` proved that the network path was working; the Go application simply has no root handler.
- `/home` returns `200`, so it is also used for the ALB health check.
- Apple Silicon local builds can produce the wrong architecture for amd64 EKS nodes, so CI explicitly builds `linux/amd64`.
- A Go module moved under `app/` requires GitHub Actions caching to use `cache-dependency-path: app/go.mod`.
- Public IPs, Terraform state, tokens, and environment-specific values should not be committed.

## Outcome

Project 2 now demonstrates a complete source-to-production-style delivery chain in one repository:

```text
Go application
+ automated test/build
+ Docker
+ Docker Hub
+ GitHub Actions
+ Terraform
+ AWS networking
+ EKS
+ IAM / Pod Identity
+ Helm
+ Argo CD
+ GitOps
+ Kubernetes
+ AWS Load Balancer Controller
+ ALB
```

It can be explained simply as: **Project 1 proved the pipeline; Project 2 rebuilt and improved the entire application platform with explicit Terraform-managed AWS infrastructure and a self-contained CI/GitOps workflow.**
