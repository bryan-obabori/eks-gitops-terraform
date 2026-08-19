# Project 2 Build Journal — Terraform EKS GitOps Platform

This journal records the sequence used to build Project 2 from an empty Terraform/GitOps repository into a live AWS EKS platform with Terraform, Argo CD, AWS Load Balancer Controller, Helm, GitOps, and a publicly reachable Go web application.

The companion `README.md` explains the finished architecture. This journal focuses on the build sequence, decisions, verification steps, and troubleshooting that happened along the way.

---

# 1. Starting Point and Goal

Project 1 had already proven the application-delivery workflow using Go, Docker, Kubernetes, Helm, GitHub Actions, Argo CD, and an EKS cluster created primarily with `eksctl`.

Project 1 is publicly available at:

**[bryan-obabori/go-web-app-devops](https://github.com/bryan-obabori/go-web-app-devops)**

Project 2 was created to rebuild the infrastructure side explicitly with Terraform and expose more of the AWS/EKS architecture that `eksctl` normally hides.

The new project repository is:

**[bryan-obabori/eks-gitops-terraform](https://github.com/bryan-obabori/eks-gitops-terraform)**

The target architecture became:

```text
Terraform
   |
   +--> AWS VPC / subnets / routing / NAT
   |
   +--> EKS control plane + private worker nodes
   |
   +--> IAM / EKS Pod Identity
   |
   +--> Argo CD
   |
   +--> AWS Load Balancer Controller
   |
   v
GitHub GitOps repository
   |
   v
Helm chart
   |
   v
Kubernetes Deployment + Service + ALB Ingress
   |
   v
Internet-facing AWS Application Load Balancer
   |
   v
Go web application
```

The important decision was to reuse the proven application assets from Project 1 while making Project 2 primarily an infrastructure and platform-engineering exercise.

---

# 2. Repository Structure

The final Project 2 repository structure is:

```text
eks-gitops-terraform/
├── argocd/
│   └── application.yaml
├── gitops/
│   └── go-web-app-chart/
│       ├── .helmignore
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
│   └── platform/
│       ├── .terraform.lock.hcl
│       ├── main.tf
│       ├── providers.tf
│       ├── variables.tf
│       └── versions.tf
├── .gitignore
├── README.md
├── TEARDOWN.md
└── JOURNAL.md
```

We intentionally kept the Terraform layout small. Instead of creating many tiny `.tf` files, related resources were grouped into a few files with clear comment separators.

---

# 3. Terraform Model Used in the Project

Before building, we established a few Terraform concepts that guided the structure of the project.

## One directory = one root module

Terraform reads all `.tf` files in the same directory together.

For example:

```text
terraform/infra/main.tf
terraform/infra/providers.tf
terraform/infra/variables.tf
terraform/infra/outputs.tf
```

are one Terraform root module, not four independent programs.

The same applies to `terraform/platform`.

## Why `infra` and `platform` were separated

We used two Terraform root modules:

```text
terraform/infra
terraform/platform
```

The separation reflects lifecycle boundaries:

```text
infra
  = VPC + networking + EKS + worker nodes

platform
  = Argo CD + Pod Identity + AWS Load Balancer Controller
```

Each root module therefore has its own:

- Terraform state
- `.terraform/` directory
- provider initialization
- provider lock file

## Terraform workflow used throughout

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

For important applies we also used saved plans:

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

The working mental model was:

```text
provider  = API bridge
variable  = external input
local     = internal computed value
data      = query an existing object/value
resource  = create/manage infrastructure
output    = expose a useful value
state     = mapping between Terraform configuration and real resources
```

`.terraform.lock.hcl` was committed because it pins provider selections. Terraform state was intentionally excluded from Git.

---

# 4. Building the AWS Network

The first major build phase was the AWS network.

We selected a two-Availability-Zone design:

```text
VPC 10.0.0.0/16

AZ A
├── Public subnet  10.0.1.0/24
└── Private subnet 10.0.11.0/24

AZ B
├── Public subnet  10.0.2.0/24
└── Private subnet 10.0.12.0/24
```

Terraform queried available Availability Zones and selected two rather than hard-coding specific zone names.

## Public subnets

Two public subnets were created with public IP mapping enabled.

They were tagged for external Kubernetes/AWS load balancer discovery:

```hcl
"kubernetes.io/role/elb" = "1"
```

## Private subnets

Two private subnets were created with public IP mapping disabled.

They were tagged for internal load balancer discovery:

```hcl
"kubernetes.io/role/internal-elb" = "1"
```

## Internet Gateway

An Internet Gateway was attached to the VPC.

The public route table used:

```text
0.0.0.0/0 -> Internet Gateway
```

## NAT Gateway design

We deliberately chose one NAT Gateway per Availability Zone:

```text
Public subnet A -> NAT Gateway A
Public subnet B -> NAT Gateway B
```

Each private subnet routes outbound traffic through the NAT Gateway in its own Availability Zone:

```text
Private subnet A -> NAT A
Private subnet B -> NAT B
```

This costs more than a single-NAT lab design, but demonstrates a more resilient multi-AZ topology.

Each NAT Gateway required an Elastic IP.

## Route tables

The final routing model was:

```text
Public route table
    0.0.0.0/0 -> Internet Gateway

Private route table A
    0.0.0.0/0 -> NAT Gateway A

Private route table B
    0.0.0.0/0 -> NAT Gateway B
```

Subnet-to-route-table associations were managed explicitly in Terraform.

## Network apply

We ran the normal Terraform sequence from the `terraform/infra` root module and applied the networking resources before adding EKS.

---

# 5. Adding EKS to the Infrastructure Layer

After the VPC was working, EKS resources were added to `terraform/infra`.

## EKS cluster IAM role

We created an IAM role trusted by:

```text
eks.amazonaws.com
```

and attached:

```text
AmazonEKSClusterPolicy
```

This role is used by the EKS control plane.

## EKS cluster

The cluster name is:

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

Bootstrap administrator permissions were enabled for the Terraform creator.

## Cluster networking

The EKS cluster was associated with the two private subnets:

```text
10.0.11.0/24
10.0.12.0/24
```

The Kubernetes API endpoint was configured with:

```text
private access = enabled
public access  = enabled
```

Public API access was restricted to an administrator `/32` CIDR rather than being open to the internet.

---

# 6. Moving the Public CIDR Out of Git

Before publishing the repository, the account/location-specific EKS API allow-list value was moved out of the tracked Terraform configuration.

`variables.tf` received:

```hcl
variable "allowed_public_cidr" {
  description = "CIDR allowed to access the EKS public API endpoint"
  type        = string
}
```

and the cluster configuration used:

```hcl
public_access_cidrs = [var.allowed_public_cidr]
```

A local file was used for the actual value:

```text
terraform/infra/terraform.tfvars
```

The repository `.gitignore` excludes:

```text
*.tfvars
*.tfvars.json
```

Before the first public push, we explicitly checked that:

```text
public CIDR was not staged
terraform.tfvars was ignored
```

Both checks passed.

---

# 7. EKS Worker Node Role and Managed Node Group

A separate IAM role was created for the EC2 worker nodes.

The trust principal is:

```text
ec2.amazonaws.com
```

The node role received:

```text
AmazonEKSWorkerNodePolicy
AmazonEC2ContainerRegistryPullOnly
AmazonEKS_CNI_Policy
```

For this learning environment, the VPC CNI policy was attached directly to the node role. A stricter production design could move CNI permissions to a dedicated workload identity.

## Managed node group

The managed node group used:

```text
instance type: t3.medium
capacity type: ON_DEMAND
minimum:       2
desired:       2
maximum:       3
```

The worker nodes were placed only in the two private subnets.

That means the nodes do not receive public IP addresses.

---

# 8. Applying and Verifying EKS

After planning and applying the EKS additions, kubeconfig was updated:

```bash
aws eks update-kubeconfig \
  --name go-web-app-cluster \
  --region us-east-1
```

The nodes were checked with:

```bash
kubectl get nodes -o wide
```

Two nodes reached `Ready` state.

Their internal addresses were distributed across the two private subnet ranges:

```text
10.0.11.x
10.0.12.x
```

Neither node had an external IP.

We also mapped the EC2 instances back to their subnets/AZs to confirm the intended multi-AZ private-node topology.

At this stage, the infrastructure layer had proven:

```text
VPC
+ public/private subnet separation
+ two NAT Gateways
+ routing
+ EKS control plane
+ two private managed workers
```

---

# 9. Building the Terraform Platform Layer

Rather than mixing Kubernetes add-ons into the same Terraform state as the VPC and EKS foundation, we created:

```text
terraform/platform
```

The platform root module uses:

- AWS provider
- Kubernetes provider
- Helm provider
- HTTP provider

Terraform queries the existing EKS cluster using data sources.

The Kubernetes and Helm providers are configured dynamically from:

- EKS endpoint
- cluster CA certificate
- EKS authentication token

This avoided hard-coding Kubernetes credentials.

---

# 10. Installing Argo CD with Terraform and Helm

Argo CD was the first platform component installed.

Terraform created an Argo CD Helm release in:

```text
argocd
```

The namespace was created automatically by the release.

The Argo CD server Service was intentionally configured as:

```text
ClusterIP
```

The Argo UI was not exposed publicly for this lab.

## Verification

After apply, we verified the Argo CD namespace and its pods.

The expected components were healthy, including:

- application controller
- applicationset controller
- dex
- notifications controller
- redis
- repo server
- server

The Argo CD server had no external IP, as intended.

---

# 11. Choosing AWS Load Balancer Controller

Project 1 had already demonstrated a different ingress approach.

For Project 2, we intentionally moved to AWS Load Balancer Controller so the project would exercise AWS-native EKS load-balancer integration.

The desired model became:

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
Kubernetes Service
       |
       v
Pod
```

---

# 12. Installing AWS Load Balancer Controller with EKS Pod Identity

The controller needed AWS permissions to create and manage ALBs, target groups, listeners, and related AWS networking resources.

Instead of placing those permissions broadly on every worker node, we used EKS Pod Identity.

## Step 1 — EKS Pod Identity Agent

Terraform installed the EKS add-on:

```text
eks-pod-identity-agent
```

The agent runs on the worker nodes and provides temporary AWS credentials to workloads with Pod Identity associations.

## Step 2 — controller IAM policy

Terraform used the HTTP provider to retrieve the official IAM policy for the AWS Load Balancer Controller version being installed.

The controller Helm chart version used in this project is:

```text
3.4.3
```

A dedicated IAM policy was created from that policy document.

## Step 3 — controller IAM role

A dedicated IAM role was created with trust for:

```text
pods.eks.amazonaws.com
```

The role trust allows:

```text
sts:AssumeRole
sts:TagSession
```

and is restricted to the intended:

- EKS cluster
- `kube-system` namespace
- `aws-load-balancer-controller` service account

## Step 4 — Kubernetes service account

Terraform created:

```text
kube-system/aws-load-balancer-controller
```

## Step 5 — Pod Identity association

Terraform associated the Kubernetes service account with the dedicated IAM role.

## Step 6 — Helm release

The AWS Load Balancer Controller was installed in:

```text
kube-system
```

The Helm release received:

- cluster name
- AWS region
- VPC ID
- the existing service account name

The chart was configured not to create a second service account because Terraform had already created the Pod Identity-linked account.

## Apply and verification

The controller addition planned seven new resources with no changes or destroys.

The apply completed successfully.

We verified:

- two AWS Load Balancer Controller pods running
- EKS Pod Identity Agent pods running on the worker nodes

At this point the AWS-native ingress control plane was operational.

---

# 13. Reusing the Proven Helm Chart from Project 1

Instead of rebuilding the application chart from scratch, the known-working Helm chart from Project 1 was reused.

Project 1 source repository:

**[bryan-obabori/go-web-app-devops](https://github.com/bryan-obabori/go-web-app-devops)**

The reusable chart is stored in Project 1 under:

```text
helm/go-web-app-chart
```

For Project 2, that chart became:

```text
gitops/go-web-app-chart
```

The chart already provided:

- Deployment
- ClusterIP Service
- Ingress
- image values

The Deployment uses the existing Docker Hub repository:

```text
bryanobabori/go-web-app
```

The application container listens on port `8080`.

The Kubernetes Service exposes port `80` and forwards to container port `8080`.

The reuse decision was intentional:

```text
Project 1 application assets = already proven
Project 2 infrastructure      = new learning focus
```

---

# 14. Converting the Helm Ingress to AWS ALB

The reused chart was adapted for AWS Load Balancer Controller.

The Ingress class was changed to:

```yaml
spec:
  ingressClassName: alb
```

Annotations were added for an internet-facing ALB:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
```

The old host-specific routing requirement was removed so the AWS-generated ALB hostname could be used directly.

## Why the Service remained ClusterIP

The ALB uses:

```text
target-type: ip
```

so pod IPs can be registered as load-balancer targets while the application Service remains:

```text
ClusterIP
```

A separate Kubernetes `LoadBalancer` Service was not required.

---

# 15. Preparing the Repository for Publication

Before publishing Project 2, `.gitignore` was created to exclude:

```text
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.tfvars
*.tfvars.json
Terraform crash logs
.DS_Store
```

Both `.terraform.lock.hcl` files were intentionally retained in version control.

We also performed two safety checks:

```text
public CIDR not staged
terraform.tfvars ignored
```

Both checks passed.

---

# 16. Creating the Project 2 GitHub Repository

The initial commit was:

```text
fafd1b9  Build Terraform EKS GitOps platform
```

The GitHub repository was created from the local project with:

```bash
gh repo create eks-gitops-terraform \
  --public \
  --source=. \
  --remote=origin \
  --push
```

The repository became:

```text
bryan-obabori/eks-gitops-terraform
```

We verified the remote and working tree with:

```bash
git remote -v
git status
```

The `main` branch was tracking `origin/main` and the working tree was clean.

---

# 17. Creating the Argo CD Application

The next step connected Argo CD to Project 2.

We created:

```text
argocd/application.yaml
```

The Argo CD Application is named:

```text
go-web-app
```

and lives in the `argocd` namespace.

Its Git source is:

```text
repository: bryan-obabori/eks-gitops-terraform
revision:   main
path:       gitops/go-web-app-chart
```

The destination is:

```text
cluster:   https://kubernetes.default.svc
namespace: default
```

Automated reconciliation was enabled with:

```yaml
automated:
  prune: true
  selfHeal: true
```

The bootstrap commit was:

```text
a62e273  Bootstrap go web app with Argo CD
```

The Application was then created in the cluster:

```bash
kubectl apply -f argocd/application.yaml
```

The first immediate check showed blank sync/health fields because Argo CD had only just received the Application object.

Rather than changing anything, we checked again after reconciliation.

---

# 18. Verifying Argo CD Reconciliation

The next check showed:

```text
SYNC STATUS   HEALTH STATUS
Synced        Healthy
```

We then verified the workload resources:

```bash
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default
```

The results showed:

- Deployment `1/1` available
- Service type `ClusterIP`
- Ingress class `alb`
- application Pod `Running`
- AWS ALB hostname present in the Ingress status

This proved that Argo CD had successfully read the repository, rendered the Helm chart, and created the Kubernetes resources.

---

# 19. First ALB Test — DNS Not Yet Available

We tried the new ALB hostname immediately with `curl`.

The result was:

```text
curl: (6) Could not resolve host
```

Instead of modifying Terraform or Kubernetes, we diagnosed the actual layer that was not ready.

We checked the ALB through AWS:

```bash
aws elbv2 describe-load-balancers
```

AWS reported:

```text
Scheme: internet-facing
State:  provisioning
```

We also checked DNS:

```bash
dig +short "$ALB"
dig +short @8.8.8.8 "$ALB"
```

Neither resolver had an answer yet.

The Kubernetes Ingress event showed:

```text
SuccessfullyReconciled
```

That told us the controller had successfully requested the ALB, while AWS was still finishing provisioning.

No infrastructure changes were needed.

---

# 20. Waiting for the ALB to Become Active

We used a shell loop to query the ALB state until AWS changed it from:

```text
provisioning
```

to:

```text
active
```

Once the ALB became active, DNS began resolving to public IPv4 addresses.

A new `curl` successfully connected to port 80.

At that point we had proven:

```text
client
  -> DNS
  -> public ALB
```

---

# 21. HTTP 404 Diagnosis

After the ALB became reachable, requesting the root path returned:

```text
HTTP/1.1 404 Not Found
404 page not found
```

This was not an infrastructure failure.

Because the ALB accepted the connection and returned an HTTP response, the traffic path was already reaching the application.

We inspected the Go application routes in Project 1 and found that the application defines:

```text
/home
/courses
/about
/contact
```

but does not define:

```text
/
```

The Go server listens on:

```text
0.0.0.0:8080
```

So the 404 was the application correctly responding to an undefined route.

---

# 22. Testing the Real Application Route

We tested the actual home route:

```bash
curl -I "http://$ALB/home"
```

The response was:

```text
HTTP/1.1 200 OK
```

This was the definitive end-to-end application verification.

It proved:

```text
Internet
   |
   v
AWS ALB
   |
   v
Kubernetes Service
   |
   v
Pod IP
   |
   v
Go server :8080
   |
   v
/home -> HTTP 200
```

---

# 23. Fixing the ALB Health Check

Because the application does not return success on `/`, the ALB health check needed to use a real application route.

The Ingress was updated with:

```yaml
alb.ingress.kubernetes.io/healthcheck-path: /home
```

The final ALB-related annotations became:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/healthcheck-path: /home
```

Because the Ingress template lives in the GitOps repository, the change was committed and pushed and Argo CD reconciled it automatically.

This aligned AWS target health checks with the application's real behavior.

---

# 24. Documentation Phase

After the platform was proven live, repository documentation was added.

## README.md

The README documents:

- architecture
- repository structure
- prerequisites
- deployment sequence
- Terraform root-module separation
- Argo CD workflow
- Pod Identity design
- ALB configuration
- verification commands
- Terraform state handling
- cost considerations

## TEARDOWN.md

The teardown guide was added because the environment contains several independently billable AWS resources and destruction order matters.

The documented sequence is:

```text
Argo CD Application
        |
        v
Application Deployment / Service / Ingress
        |
        v
AWS Application Load Balancer deletion
        |
        v
Terraform platform destroy
        |
        v
Terraform infrastructure destroy
        |
        v
AWS orphan-resource checks
```

The GitOps application is removed first so the AWS Load Balancer Controller can delete the ALB while the EKS cluster is still operational.

---

# 25. Cost Awareness

The live lab environment includes billable AWS resources such as:

- EKS control plane
- two `t3.medium` EC2 worker nodes
- two NAT Gateways
- Elastic IPs associated with the NAT Gateways
- Application Load Balancer

The dual-NAT design was chosen intentionally for the architecture exercise, not because it is the cheapest possible lab configuration.

The environment should be destroyed when it is no longer needed by following `TEARDOWN.md`.

---

# 26. What Was Reused vs Built New

This distinction is useful when explaining the project.

## Reused from Project 1

From **[bryan-obabori/go-web-app-devops](https://github.com/bryan-obabori/go-web-app-devops)**:

```text
Go application
Docker image repository
known-working Helm chart structure
Deployment pattern
ClusterIP Service pattern
GitHub Actions application-image workflow
```

## Built specifically for Project 2

```text
Terraform VPC architecture
public/private multi-AZ subnets
Internet Gateway
NAT Gateways
route tables
EKS control plane in Terraform
private managed node group
EKS IAM roles
Terraform platform layer
Argo CD Helm installation in Terraform
EKS Pod Identity Agent
AWS Load Balancer Controller IAM role/policy
Pod Identity association
AWS Load Balancer Controller Helm installation
ALB ingress conversion
GitOps bootstrap Application
Project 2 README
Project 2 teardown guide
Project 2 build journal
```

The reuse kept the project focused on infrastructure and platform engineering instead of rebuilding an application that had already been proven.

---

# 27. Troubleshooting Lessons

## Lesson 1 — Identify the failing layer before changing infrastructure

When `curl` could not resolve the ALB hostname, the first checks were AWS ALB state and DNS.

The ALB was still provisioning.

No Terraform or Kubernetes changes were required.

## Lesson 2 — An HTTP 404 can prove most of the stack works

The ALB returned an application-generated 404 for `/`.

That meant:

```text
DNS worked
TCP connection worked
ALB listener worked
Ingress routing worked
Service routing worked
Pod networking worked
Go process responded
```

Only the requested application route was incorrect.

## Lesson 3 — Inspect application behavior before changing networking

The application source showed `/home` was valid while `/` was not.

Testing `/home` immediately returned HTTP 200.

## Lesson 4 — Health checks must match real application behavior

The ALB health-check path was explicitly set to `/home` rather than relying on the default `/` path.

## Lesson 5 — Keep environment-specific values out of public Git

The EKS API allow-list CIDR was moved into ignored `terraform.tfvars` before the repository was published.

## Lesson 6 — Terraform exposes architecture that higher-level tools hide

Much of the difficulty in Project 2 was not Terraform syntax itself. The real complexity came from making AWS/EKS requirements explicit:

- subnet design
- route tables
- NAT
- IAM
- EKS control-plane permissions
- private worker nodes
- provider authentication
- Pod Identity
- load-balancer integration

That visibility was one of the main learning goals of Project 2.

---

# 28. Useful Verification Commands

## EKS nodes

```bash
kubectl get nodes -o wide
```

## Argo CD application

```bash
kubectl get application go-web-app -n argocd
```

Expected:

```text
Synced   Healthy
```

## Application resources

```bash
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default
```

## AWS Load Balancer Controller and Pod Identity Agent

```bash
kubectl get pods -n kube-system | \
  grep -E 'aws-load-balancer-controller|eks-pod-identity-agent'
```

## ALB hostname

```bash
ALB=$(kubectl get ingress go-web-app \
  -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "$ALB"
```

## ALB state

```bash
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query "LoadBalancers[?DNSName=='$ALB'].{DNS:DNSName,State:State.Code,Scheme:Scheme}" \
  --output table
```

## DNS

```bash
dig +short "$ALB"
```

## Live application

```bash
curl -I "http://$ALB/home"
```

Expected:

```text
HTTP/1.1 200 OK
```

## Health-check annotation

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

# 29. Terraform Commands Used Most Often

## Infrastructure layer

```bash
terraform -chdir=terraform/infra init
terraform -chdir=terraform/infra fmt
terraform -chdir=terraform/infra validate
terraform -chdir=terraform/infra plan -out=tfplan
terraform -chdir=terraform/infra apply tfplan
```

## Platform layer

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform fmt
terraform -chdir=terraform/platform validate
terraform -chdir=terraform/platform plan -out=tfplan
terraform -chdir=terraform/platform apply tfplan
```

## Kubeconfig

```bash
aws eks update-kubeconfig \
  --name go-web-app-cluster \
  --region us-east-1
```

## GitOps bootstrap

```bash
kubectl apply -f argocd/application.yaml
```

---

# 30. Final Architecture Summary

```text
                         GitHub
                           |
                           | main branch
                           v
                       Argo CD
                           |
                           | Helm render / reconciliation
                           v
                +-----------------------+
                | Kubernetes on EKS     |
                |                       |
                | Deployment            |
                | Service: ClusterIP    |
                | Ingress: alb          |
                +-----------+-----------+
                            |
                            v
               AWS Load Balancer Controller
                            |
                EKS Pod Identity + IAM
                            |
                            v
                Internet-facing AWS ALB
                            |
                            v
                      Go web app

AWS foundation managed by Terraform:

VPC 10.0.0.0/16
|
+-- Public subnet A 10.0.1.0/24 -- NAT A
|                                  |
|                                  +--> Private A 10.0.11.0/24
|                                         |
|                                         +--> EKS worker
|
+-- Public subnet B 10.0.2.0/24 -- NAT B
                                   |
                                   +--> Private B 10.0.12.0/24
                                          |
                                          +--> EKS worker
```

---

# 31. Interview Explanation

A concise way to explain Project 2:

> I rebuilt an EKS application platform with Terraform rather than relying on `eksctl`. I explicitly provisioned the VPC, public and private subnets, NAT gateways, routing, EKS control plane, IAM roles, and a private managed node group across two Availability Zones. I separated the Kubernetes platform components into a second Terraform root module, installed Argo CD and AWS Load Balancer Controller with Helm, and used EKS Pod Identity to give the controller dedicated AWS permissions. I reused a proven Helm application chart from my earlier EKS project, converted its ingress to AWS ALB, and used an Argo CD Application with automated sync, prune, and self-heal to deploy it from Git. I verified the complete path through an internet-facing ALB and debugged both ALB DNS provisioning and an application-route 404 before aligning the ALB health check with the actual `/home` endpoint.

Useful tradeoffs to discuss:

- two NAT Gateways vs one cheaper NAT Gateway
- private nodes vs public nodes
- Pod Identity vs broad worker-node permissions
- separate Terraform states vs one large state
- AWS ALB ingress vs a separate ingress-controller pattern
- GitOps reconciliation vs direct `kubectl apply`
- local Terraform state for a lab vs remote state for a shared environment

---

# 32. Project Completion State

Project 2 is complete when all of the following are true:

```text
[✓] Terraform network applied
[✓] EKS cluster applied
[✓] two private worker nodes Ready
[✓] Argo CD installed
[✓] EKS Pod Identity Agent installed
[✓] AWS Load Balancer Controller installed
[✓] Helm chart stored in Project 2 GitOps path
[✓] Argo CD Application bootstrapped
[✓] Argo reports Synced / Healthy
[✓] application Pod Running
[✓] internet-facing ALB Active
[✓] /home returns HTTP 200
[✓] ALB health check uses /home
[✓] README written
[✓] teardown guide written
[✓] build journal written
```

The only lifecycle step intentionally left for later is destruction of the live AWS lab environment.

Follow `TEARDOWN.md` when that time comes.
