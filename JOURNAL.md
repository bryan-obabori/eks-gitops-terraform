# Project 2 Build Journal — Terraform EKS GitOps Platform

This journal records how Project 2 evolved from an empty Terraform/GitOps repository into a live AWS EKS platform with Terraform-managed infrastructure, Terraform-managed platform components, Terraform-managed Argo CD bootstrap, and Argo-managed application delivery.

The `README.md` is the operational source of truth for how to build and destroy the environment. This journal preserves the chronological build decisions, troubleshooting, and lessons learned.

---

# 1. Starting Point

Project 1 had already proven the application-delivery workflow using Go, Docker, Kubernetes, Helm, GitHub Actions, Argo CD, and EKS created primarily with `eksctl`.

Project 1 is public at:

**[bryan-obabori/go-web-app-devops](https://github.com/bryan-obabori/go-web-app-devops)**

Project 2 was created to rebuild the infrastructure side explicitly with Terraform so the AWS/EKS architecture hidden by higher-level tooling would be visible and understandable.

Project 2 repository:

**[bryan-obabori/eks-gitops-terraform](https://github.com/bryan-obabori/eks-gitops-terraform)**

---

# 2. Original Target Architecture

The initial target was:

```text
Terraform
   |
   +--> AWS VPC / subnets / routing / NAT
   +--> EKS control plane + private worker nodes
   +--> IAM / EKS Pod Identity
   +--> Argo CD
   +--> AWS Load Balancer Controller
   |
   v
GitOps repository
   |
   v
Helm chart
   |
   v
Deployment + Service + Ingress
   |
   v
AWS ALB
   |
   v
Go web application
```

The application assets were deliberately reused from Project 1 so Project 2 could stay focused on infrastructure and platform engineering.

---

# 3. Terraform Root-Module Model

A key concept established early was that Terraform reads all `.tf` files in the same directory as one root module.

The project initially used two root modules:

```text
terraform/infra
terraform/platform
```

Later, a third root module was added:

```text
terraform/apps
```

The final lifecycle boundaries are:

```text
infra
  = VPC + networking + EKS + worker nodes + core IAM

platform
  = Argo CD + Pod Identity + AWS Load Balancer Controller

apps
  = Argo CD Application bootstrap object
```

Each root module has independent Terraform state and provider initialization.

---

# 4. Building the AWS Network

The VPC design uses:

```text
VPC 10.0.0.0/16

AZ A
├── Public subnet  10.0.1.0/24
└── Private subnet 10.0.11.0/24

AZ B
├── Public subnet  10.0.2.0/24
└── Private subnet 10.0.12.0/24
```

Terraform queries available Availability Zones instead of hard-coding specific zone names.

Public subnets are tagged for external load-balancer discovery:

```hcl
"kubernetes.io/role/elb" = "1"
```

Private subnets are tagged for internal load-balancer discovery:

```hcl
"kubernetes.io/role/internal-elb" = "1"
```

The VPC includes an Internet Gateway and one NAT Gateway per Availability Zone.

The routing model is:

```text
Public route table
    0.0.0.0/0 -> Internet Gateway

Private route table A
    0.0.0.0/0 -> NAT Gateway A

Private route table B
    0.0.0.0/0 -> NAT Gateway B
```

The two-NAT design costs more than a single-NAT lab, but demonstrates AZ-independent private-subnet egress.

---

# 5. Adding EKS

The EKS cluster is named:

```text
go-web-app-cluster
```

The cluster was configured for EKS/Kubernetes version:

```text
1.35
```

Authentication mode:

```text
API_AND_CONFIG_MAP
```

The cluster API endpoint has both private and public access enabled, while public access is restricted to an administrator `/32` CIDR.

A dedicated EKS control-plane IAM role was created and attached to `AmazonEKSClusterPolicy`.

---

# 6. Keeping the Administrator Public IP Out of Git

The allowed EKS API CIDR was moved into an input variable:

```hcl
variable "allowed_public_cidr" {
  description = "CIDR allowed to access the EKS public API endpoint"
  type        = string
}
```

The actual value lives in:

```text
terraform/infra/terraform.tfvars
```

That file is intentionally ignored by Git.

This kept account/location-specific public-IP data out of the public repository while still allowing Terraform to control the EKS endpoint allow list.

---

# 7. Managed Worker Nodes

A separate IAM role was created for EC2 worker nodes with:

```text
AmazonEKSWorkerNodePolicy
AmazonEC2ContainerRegistryPullOnly
AmazonEKS_CNI_Policy
```

The managed node group uses:

```text
instance type: t3.medium
capacity type: ON_DEMAND
minimum:       2
desired:       2
maximum:       3
```

Workers are placed only in the two private subnets and do not receive public IP addresses.

After apply, `kubectl get nodes -o wide` showed two Ready nodes distributed across the `10.0.11.x` and `10.0.12.x` private ranges.

---

# 8. Creating the Platform Layer

A separate Terraform root module was created at:

```text
terraform/platform
```

It uses AWS, Kubernetes, Helm, and HTTP providers.

Terraform queries the existing EKS cluster and dynamically configures the Kubernetes and Helm providers using:

- EKS endpoint
- cluster CA certificate
- EKS authentication token

This avoids hard-coded Kubernetes credentials.

---

# 9. Installing Argo CD

Argo CD was installed with Terraform through Helm into:

```text
argocd
```

The Argo CD server Service was deliberately kept as:

```text
ClusterIP
```

The UI was not exposed publicly.

The expected Argo components reached healthy running states after the platform apply.

---

# 10. Choosing AWS Load Balancer Controller

Project 2 intentionally moved away from the ingress approach used in Project 1 and adopted AWS Load Balancer Controller.

The intended traffic path became:

```text
Kubernetes Ingress
       |
       v
AWS Load Balancer Controller
       |
       v
AWS Application Load Balancer
       |
       v
ClusterIP Service
       |
       v
Pod
```

This provided direct experience with AWS-native EKS ingress integration.

---

# 11. EKS Pod Identity for the Load Balancer Controller

The controller needed AWS permissions for ALBs, target groups, listeners, and related resources.

Rather than adding broad permissions to the worker-node role, the project used EKS Pod Identity.

Terraform installed:

```text
eks-pod-identity-agent
```

A dedicated controller IAM policy and IAM role were created.

The role trusts:

```text
pods.eks.amazonaws.com
```

and is restricted to:

- the intended EKS cluster
- `kube-system`
- `aws-load-balancer-controller`

Terraform then created the service account, Pod Identity association, and AWS Load Balancer Controller Helm release.

Verification showed controller pods and Pod Identity Agent pods running successfully.

---

# 12. Reusing the Project 1 Helm Chart

The known-working application chart from Project 1 was reused.

Project 1 chart path:

```text
helm/go-web-app-chart
```

Project 2 GitOps path:

```text
gitops/go-web-app-chart
```

The chart already provided:

- Deployment
- ClusterIP Service
- Ingress
- image configuration

The application image repository remained:

```text
bryanobabori/go-web-app
```

The container listens on `8080`; the Service exposes `80` and forwards to `8080`.

---

# 13. Converting the Ingress to AWS ALB

The reused ingress configuration was changed to:

```yaml
spec:
  ingressClassName: alb
```

with:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
```

The Service remained `ClusterIP` because ALB IP target mode registers pod IPs directly.

---

# 14. Publishing Project 2

Before the repository was published, `.gitignore` excluded:

```text
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.tfvars
*.tfvars.json
.DS_Store
```

Provider lock files were intentionally committed.

The initial project commit was:

```text
fafd1b9  Build Terraform EKS GitOps platform
```

---

# 15. Initial Argo CD Application Bootstrap

The Argo CD Application manifest was created at:

```text
argocd/application.yaml
```

It points to:

```text
repository: bryan-obabori/eks-gitops-terraform
revision:   main
path:       gitops/go-web-app-chart
```

with destination:

```text
cluster:   https://kubernetes.default.svc
namespace: default
```

and automated reconciliation:

```yaml
automated:
  prune: true
  selfHeal: true
```

At this stage of the project, the Application was initially bootstrapped manually with:

```bash
kubectl apply -f argocd/application.yaml
```

That was later improved so Terraform owns this bootstrap object as well.

---

# 16. Argo CD Reconciliation

After the Application was created, Argo CD reconciled the Helm chart and reported:

```text
Synced
Healthy
```

The cluster then contained:

- Deployment `1/1`
- running application pod
- ClusterIP Service
- ALB Ingress
- AWS-generated ALB hostname

This proved the Git-to-Argo-to-Kubernetes path was functioning.

---

# 17. ALB DNS Troubleshooting

The first immediate request to the ALB hostname failed with:

```text
curl: (6) Could not resolve host
```

Instead of changing Terraform or Kubernetes, the ALB was checked through AWS.

Its state was:

```text
provisioning
```

The Kubernetes Ingress event already showed successful reconciliation.

The correct diagnosis was that AWS was still creating the load balancer and DNS record.

No configuration change was needed.

---

# 18. ALB Becomes Active

Once the ALB changed from:

```text
provisioning
```

to:

```text
active
```

DNS began resolving and HTTP traffic reached the application.

This validated:

```text
Internet
  -> ALB
  -> Kubernetes Service
  -> Pod
```

---

# 19. Diagnosing the HTTP 404

The root URL returned:

```text
HTTP/1.1 404 Not Found
```

This turned out to be an application-routing issue, not an infrastructure failure.

The Go application defines:

```text
/home
/courses
/about
/contact
```

but intentionally has no handler for:

```text
/
```

The 404 therefore proved that DNS, TCP, ALB routing, Kubernetes networking, the Service, pod networking, and the Go server were already functioning.

---

# 20. Verifying the Real Application Route

Testing:

```bash
curl -I "http://$ALB/home"
```

returned:

```text
HTTP/1.1 200 OK
```

This became the definitive end-to-end application check.

---

# 21. Fixing the ALB Health Check

Because `/` does not return success, the Ingress was updated with:

```yaml
alb.ingress.kubernetes.io/healthcheck-path: /home
```

The final ALB annotations are:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/healthcheck-path: /home
```

Argo CD reconciled the change from Git automatically.

---

# 22. Realizing the Bootstrap Was Still Outside Terraform

After the platform was complete, the lifecycle model was reviewed.

Terraform already managed:

```text
VPC
EKS
worker nodes
Argo CD installation
AWS Load Balancer Controller
Pod Identity
```

but the `go-web-app` Argo CD Application had originally been created with `kubectl`.

That meant the Application existed in Kubernetes but was not represented in Terraform state.

The goal was then tightened: Terraform should control the full infrastructure/bootstrap lifecycle while Argo CD should retain ownership of workload reconciliation.

---

# 23. Adding the Third Terraform Layer — `terraform/apps`

A third root module was created:

```text
terraform/apps
```

It uses the AWS and Kubernetes providers to connect to the existing EKS cluster.

The Argo Application is represented as:

```hcl
resource "kubernetes_manifest" "go_web_app" {
  manifest = yamldecode(
    file("${path.module}/../../argocd/application.yaml")
  )

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }
}
```

The Application manifest was also given the Argo cascading resource finalizer:

```yaml
finalizers:
  - resources-finalizer.argocd.argoproj.io
```

This is important for ordered destruction: removing the Application causes Argo CD to clean up the workload resources it owns before the platform and cluster disappear.

---

# 24. Importing the Existing Argo Application into Terraform

The existing live Application was imported rather than deleted and recreated:

```bash
terraform -chdir=terraform/apps import \
  kubernetes_manifest.go_web_app \
  'apiVersion=argoproj.io/v1alpha1,kind=Application,namespace=argocd,name=go-web-app'
```

Terraform reported a successful import.

The subsequent plan showed:

```text
Plan: 0 to add, 1 to change, 0 to destroy
```

The only intended live change was adding the finalizer and bringing the object under Terraform field management.

After apply:

```text
Argo Application: Synced / Healthy
Deployment:       1/1
Ingress:          active
```

There was no intentional application recreation or downtime.

The ownership transition was committed as:

```text
a2dd146  Manage Argo CD application with Terraform
```

---

# 25. Final Ownership Model

The final design is:

```text
Terraform
│
├── terraform/infra
│   ├── VPC
│   ├── subnets
│   ├── routing
│   ├── NAT Gateways
│   ├── IAM
│   ├── EKS
│   └── managed node group
│
├── terraform/platform
│   ├── Argo CD
│   ├── EKS Pod Identity Agent
│   ├── AWS Load Balancer Controller
│   └── controller IAM / Pod Identity
│
└── terraform/apps
    └── Argo CD Application
            │
            v
         Argo CD
            ├── Deployment
            ├── Service
            └── Ingress
                    │
                    v
          AWS Load Balancer Controller
                    │
                    v
                   ALB
```

Terraform owns the bootstrap boundary. Argo CD owns workload reconciliation. AWS Load Balancer Controller owns the AWS load-balancer resources derived from the Kubernetes Ingress.

This avoids dual ownership of Deployment, Service, and Ingress between Terraform and Argo CD.

---

# 26. Final Start Order

The final rebuild sequence is:

```text
terraform/infra apply
        |
        v
aws eks update-kubeconfig
        |
        v
terraform/platform apply
        |
        v
terraform/apps apply
        |
        v
Argo CD deploys application from Git
```

The exact operational commands are maintained in `README.md`.

There is no normal manual `kubectl apply -f argocd/application.yaml` step anymore.

---

# 27. Final Destroy Order

Destruction runs in reverse ownership order:

```text
terraform/apps destroy
        |
        v
Argo Application removed
        |
        v
Argo deletes Deployment / Service / Ingress
        |
        v
AWS Load Balancer Controller removes ALB
        |
        v
terraform/platform destroy
        |
        v
terraform/infra destroy
```

The EKS cluster must not be destroyed first because the in-cluster controllers need to remain available long enough to clean up application and ALB resources.

The exact destroy commands are maintained in `README.md`.

---

# 28. Cost Awareness

The live environment includes billable AWS resources such as:

- EKS control plane
- two `t3.medium` worker nodes
- two NAT Gateways
- NAT Gateway Elastic IPs
- Application Load Balancer

The dual-NAT topology was intentionally chosen for the architecture exercise, not because it is the cheapest lab configuration.

The environment should be destroyed when it is not needed.

---

# 29. Local Terraform State

Terraform state is local for this lab and intentionally excluded from Git.

This means the normal start/destroy workflow assumes the same local checkout and state files remain available.

A production-oriented next step would be moving all root modules to a remote backend with locking and controlled access.

Provider lock files remain committed intentionally.

---

# 30. What Was Reused vs Built New

## Reused from Project 1

```text
Go application
Docker image repository
Helm chart structure
Deployment pattern
ClusterIP Service pattern
GitHub Actions image workflow
```

## Built for Project 2

```text
Terraform VPC architecture
public/private multi-AZ subnets
Internet Gateway
NAT Gateways
route tables
EKS control plane
private managed node group
EKS IAM roles
Terraform platform layer
Argo CD Helm installation
EKS Pod Identity Agent
AWS Load Balancer Controller IAM role/policy
Pod Identity association
AWS Load Balancer Controller Helm installation
ALB ingress conversion
Terraform apps layer
Terraform-managed Argo CD Application
ALB /home health-check alignment
README lifecycle documentation
build journal
```

---

# 31. Main Troubleshooting Lessons

## Diagnose the failing layer first

The initial ALB DNS failure was caused by the load balancer still provisioning, not by incorrect Terraform or Kubernetes configuration.

## A 404 can be useful evidence

The root-path 404 proved most of the infrastructure path was already healthy. The application simply did not define `/`.

## Match health checks to real application behavior

The ALB health check was explicitly moved to `/home`, which returns HTTP 200.

## Keep environment-specific inputs out of public Git

The administrator public CIDR belongs in ignored `terraform.tfvars`, not committed Terraform code.

## Terraform state determines ownership

A Kubernetes object existing in the cluster does not mean Terraform manages it. The Argo Application had to be imported into `terraform/apps` state.

## Avoid dual ownership

Terraform owns the Argo Application bootstrap object, but Argo CD retains ownership of Deployment, Service, and Ingress. That keeps the GitOps boundary clean.

---

# 32. Useful Verification Commands

```bash
kubectl get nodes -o wide
kubectl get application go-web-app -n argocd
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default
kubectl get pods -n kube-system | grep -E 'aws-load-balancer-controller|eks-pod-identity-agent'
```

Retrieve and test the ALB:

```bash
ALB=$(kubectl get ingress go-web-app \
  -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "$ALB"
curl -I "http://$ALB/home"
```

Expected application response:

```text
HTTP/1.1 200 OK
```

Verify the ALB health-check path:

```bash
kubectl get ingress go-web-app \
  -n default \
  -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/healthcheck-path}{"\n"}'
```

Expected:

```text
/home
```

---

# 33. Interview Explanation

A concise way to explain Project 2:

> I rebuilt an EKS application platform with Terraform instead of relying on `eksctl`. I explicitly provisioned the VPC, public and private subnets, NAT gateways, routing, EKS control plane, IAM roles, and private managed workers across two Availability Zones. I separated the lifecycle into three Terraform root modules: infrastructure, platform, and application bootstrap. The platform layer installs Argo CD and AWS Load Balancer Controller, and I used EKS Pod Identity to give the controller a dedicated AWS identity. Terraform then manages the Argo CD Application custom resource, while Argo CD owns the application Deployment, Service, and ALB Ingress from Git. I verified the full path through an internet-facing ALB and debugged both ALB DNS provisioning and an application-level 404 before aligning the health check with the real `/home` endpoint.

Useful tradeoffs to discuss:

- two NAT Gateways vs one cheaper NAT Gateway
- private nodes vs public nodes
- Pod Identity vs broad worker-node permissions
- three Terraform states vs one large state
- Terraform bootstrap ownership vs Argo workload ownership
- ALB ingress vs other ingress-controller approaches
- local state vs a remote backend

---

# 34. Final Project State

```text
[✓] Terraform network applied
[✓] EKS cluster applied
[✓] two private worker nodes Ready
[✓] Argo CD installed through Terraform
[✓] EKS Pod Identity Agent installed
[✓] AWS Load Balancer Controller installed
[✓] Helm chart stored in Project 2 GitOps path
[✓] Argo CD Application managed by Terraform
[✓] Argo reports Synced / Healthy
[✓] application pod Running
[✓] internet-facing ALB Active
[✓] /home returns HTTP 200
[✓] ALB health check uses /home
[✓] README contains build and destroy lifecycle
[✓] build journal updated to final architecture
```

Project 2 now has a clean Terraform-to-GitOps ownership chain and a reproducible start/destroy lifecycle documented in `README.md`.
