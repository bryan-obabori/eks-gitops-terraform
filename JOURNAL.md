# Project 2 Build Journal — Terraform EKS GitOps Platform

This journal records the actual sequence used to build Project 2 from an empty Terraform/GitOps repository into a live AWS EKS platform with Argo CD, AWS Load Balancer Controller, Helm, GitOps, and a publicly reachable Go web application.

It is intentionally more chronological than `README.md`. The README explains the final architecture; this file records how we got there, including design choices, verification commands, mistakes, troubleshooting, and fixes.

---

# 1. Project Goal

Project 1 had already proven the application-delivery workflow using:

- Go
- Docker
- Kubernetes
- Helm
- GitHub Actions
- Argo CD
- EKS created with `eksctl`
- an ingress controller

Project 2 was created to rebuild the infrastructure side more explicitly with Terraform and to make the EKS architecture closer to a production-style AWS design.

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

Project 1 was deliberately left intact as the completed `eksctl` version. We reused proven application assets from it rather than rebuilding everything from scratch.

---

# 2. Local Project Layout

The new local project directory was:

```text
/Users/bryanobabori/Documents/go-web-app/eks-gitops-terraform
```

The final repository structure became:

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

We kept the Terraform layout intentionally small. Instead of creating many tiny files, related resources were grouped into a few files with clear comment separators.

---

# 3. Terraform Model We Used

Before building, we clarified a few Terraform concepts that became important throughout the project.

## A Terraform directory is one root module

Terraform reads all `.tf` files in the same directory together.

For example:

```text
terraform/infra/main.tf
terraform/infra/providers.tf
terraform/infra/variables.tf
terraform/infra/outputs.tf
```

are not independent programs. They are all part of one Terraform root module.

The same is true for `terraform/platform`.

## Why `infra` and `platform` were separated

We intentionally used two Terraform root modules:

```text
terraform/infra
terraform/platform
```

This means they also have separate:

- Terraform state
- `.terraform/` directories
- provider initialization
- lock files

The separation reflects lifecycle boundaries:

```text
infra
  = VPC + networking + EKS + worker nodes

platform
  = Argo CD + Pod Identity + AWS Load Balancer Controller
```

## Terraform workflow used repeatedly

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

The mental model used throughout the project was:

```text
provider  = API bridge
variable  = external input
local     = internal computed value
data      = query an existing object/value
resource  = create/manage infrastructure
output    = expose a useful value
state     = Terraform's mapping between configuration and real resources
```

The `.terraform.lock.hcl` file was committed because it pins provider selections. Terraform state was not committed.

---

# 4. Building the AWS Network

The first major build phase was the VPC and subnet architecture.

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

Terraform queried available Availability Zones and selected the first two rather than hard-coding zone names.

## Public subnets

The two public subnets were created with public IP mapping enabled.

They were tagged for Kubernetes/AWS external load balancer discovery:

```hcl
"kubernetes.io/role/elb" = "1"
```

## Private subnets

The two private subnets were created with public IP mapping disabled.

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

## NAT Gateway decision

We deliberately chose two NAT Gateways:

```text
Public subnet A -> NAT Gateway A
Public subnet B -> NAT Gateway B
```

Each private subnet routes outbound traffic through the NAT Gateway in its own Availability Zone:

```text
Private subnet A -> NAT A
Private subnet B -> NAT B
```

This costs more than a single-NAT lab design, but it demonstrates an AZ-independent production-style topology.

Each NAT Gateway required its own Elastic IP.

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

Subnet-to-route-table associations were created explicitly in Terraform.

## Network apply

We ran the normal Terraform sequence in `terraform/infra` and applied the network resources.

The network layer completed successfully before EKS was added.

---

# 5. Adding EKS to the Infrastructure Layer

After the VPC was working, we added EKS resources to the same `terraform/infra` root module.

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

The cluster name used throughout the project was:

```text
go-web-app-cluster
```

The cluster was configured with Kubernetes/EKS version:

```text
1.35
```

Authentication mode:

```text
API_AND_CONFIG_MAP
```

and the Terraform creator was allowed bootstrap administrator access.

## Cluster networking

The EKS control plane was connected to the two private subnets:

```text
10.0.11.0/24
10.0.12.0/24
```

The Kubernetes API endpoint was configured with both:

```text
private access = enabled
public access  = enabled
```

Public access was restricted to the administrator's current `/32` public CIDR rather than being open to the world.

---

# 6. Removing the Public IP from Git

Initially, the allowed public API CIDR was directly present in the Terraform configuration.

Before publishing the repository, we moved it into a local variable file.

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

A local file was created:

```text
terraform/infra/terraform.tfvars
```

with the current `/32` CIDR.

The repository `.gitignore` was configured to ignore:

```text
*.tfvars
*.tfvars.json
```

We explicitly verified that the public IP was not staged and that `terraform.tfvars` was ignored before the first GitHub push.

This was an important cleanup step because the repo was intended to be public.

---

# 7. EKS Worker Node Role and Managed Node Group

We created a separate IAM role for EC2 worker nodes.

The trust principal was:

```text
ec2.amazonaws.com
```

The node role received:

```text
AmazonEKSWorkerNodePolicy
AmazonEC2ContainerRegistryPullOnly
AmazonEKS_CNI_Policy
```

For this learning project, the VPC CNI policy was attached directly to the worker-node role.

We noted that a tighter production design could place CNI permissions on a dedicated identity instead.

## Node group configuration

The managed node group used:

```text
instance type: t3.medium
capacity type: ON_DEMAND
minimum:       2
preferred:     2
maximum:       3
```

The worker nodes were placed only in the two private subnets.

That means the nodes did not receive public IP addresses.

---

# 8. Applying and Verifying EKS

After planning and applying the EKS additions, we updated the local kubeconfig:

```bash
aws eks update-kubeconfig \
  --name go-web-app-cluster \
  --region us-east-1
```

We verified the cluster using:

```bash
kubectl get nodes -o wide
```

Two nodes were `Ready`.

They were distributed across the two private subnet ranges:

```text
10.0.11.x
10.0.12.x
```

and neither node had an external IP.

We also mapped the EC2 instances back to their subnets/AZs to verify the intended multi-AZ private-node topology.

At this point the infrastructure layer had proven:

```text
VPC
+ public/private subnet separation
+ dual NAT Gateways
+ routing
+ EKS control plane
+ two private managed workers
```

---

# 9. Building the Terraform Platform Layer

Rather than mixing Kubernetes add-ons into the same state as the VPC/EKS foundation, we created:

```text
terraform/platform
```

## Providers

The platform layer used:

- AWS provider
- Kubernetes provider
- Helm provider
- HTTP provider

The AWS provider was configured for `us-east-1`.

Terraform queried the existing EKS cluster using data sources.

The Kubernetes and Helm providers were dynamically configured with:

- the EKS endpoint
- the cluster CA certificate
- an EKS authentication token

This avoided hard-coding Kubernetes credentials.

---

# 10. Installing Argo CD with Terraform + Helm

Argo CD was the first platform component installed.

Terraform created a Helm release using the Argo Helm repository.

The namespace was:

```text
argocd
```

and Terraform was allowed to create it.

The Argo CD server Service was deliberately configured as:

```text
ClusterIP
```

We did not expose the Argo CD UI publicly for this lab.

## Verification

After apply, we checked the Argo namespace.

The expected Argo components were healthy, including:

- application controller
- applicationset controller
- dex
- notifications controller
- redis
- repo server
- server

The server Service showed no public external IP, as intended.

---

# 11. Ingress Architecture Decision

Project 1 had used ingress-nginx.

For Project 2 we intentionally changed the architecture and used AWS Load Balancer Controller instead.

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

This was also a better fit for learning AWS-native EKS load-balancer integration.

---

# 12. AWS Load Balancer Controller with EKS Pod Identity

We wanted the AWS Load Balancer Controller to have a dedicated AWS identity instead of giving broad ALB permissions to every worker node.

We used EKS Pod Identity.

## Step 1 — Pod Identity Agent

Terraform installed the EKS add-on:

```text
eks-pod-identity-agent
```

The agent runs on the worker nodes and delivers temporary AWS credentials to associated Kubernetes workloads.

## Step 2 — controller IAM policy

Terraform used the HTTP provider to retrieve the official IAM policy corresponding to the AWS Load Balancer Controller version used by the project.

The controller Helm/chart version was:

```text
3.4.3
```

A dedicated IAM policy was then created from that policy document.

## Step 3 — controller IAM role

A dedicated IAM role was created with trust for:

```text
pods.eks.amazonaws.com
```

The trust allowed:

```text
sts:AssumeRole
sts:TagSession
```

and was restricted to the intended:

- EKS cluster
- `kube-system` namespace
- `aws-load-balancer-controller` service account

## Step 4 — Kubernetes service account

Terraform created:

```text
kube-system/aws-load-balancer-controller
```

## Step 5 — Pod Identity association

Terraform associated that service account with the controller IAM role.

## Step 6 — Helm release

The AWS Load Balancer Controller was installed into:

```text
kube-system
```

The Helm release was given:

- cluster name
- region
- VPC ID
- the existing Kubernetes service account

The chart was told not to create a new service account because Terraform had already created the Pod Identity-linked one.

## Platform plan/apply

The Load Balancer Controller addition planned seven new resources and no changes/destructions.

The apply completed successfully.

## Verification

We verified:

- two AWS Load Balancer Controller pods running
- the EKS Pod Identity Agent running on both worker nodes

At this point the AWS-native ingress control plane was operational.

---

# 13. Reusing the Proven Helm Chart from Project 1

Instead of rebuilding the application chart from scratch, we reused the known-working Helm chart from Project 1.

The Project 1 local source was:

```text
/Users/bryanobabori/Documents/go-web-app/go-web-app
```

We copied:

```text
helm/go-web-app-chart
```

into Project 2 as:

```text
gitops/go-web-app-chart
```

The copied chart already had:

- Deployment
- ClusterIP Service
- Ingress
- image values

The Deployment used the existing Docker Hub image repository:

```text
bryanobabori/go-web-app
```

The container listens on port `8080`.

The Kubernetes Service exposes port `80` and forwards to container port `8080`.

This reuse was deliberate:

```text
Project 1 application assets = proven
Project 2 infrastructure      = new learning focus
```

---

# 14. Converting the Helm Ingress from NGINX to AWS ALB

The copied chart originally contained ingress-nginx-specific configuration and a local host name.

For Project 2, the ingress was changed to:

```yaml
spec:
  ingressClassName: alb
```

Annotations were added for an internet-facing ALB:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
```

The hard-coded local hostname was removed.

This allowed direct access through the AWS-generated ALB DNS name.

## Why the Service stayed ClusterIP

Because the ALB uses:

```text
target-type: ip
```

the controller can register Pod IPs as targets while the Kubernetes Service remains:

```text
ClusterIP
```

We did not need a `LoadBalancer` Service for the application.

---

# 15. Preparing the Git Repository for Publication

Before publishing Project 2, `.gitignore` was created to exclude:

```text
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.tfvars
*.tfvars.json
crash logs
macOS .DS_Store
```

We intentionally kept both Terraform provider lock files under version control.

We then performed two safety checks:

```text
public IP not staged
terraform.tfvars ignored
```

Both checks passed.

---

# 16. Creating the GitHub Repository

The initial project commit was:

```text
fafd1b9  Build Terraform EKS GitOps platform
```

The repository was created with GitHub CLI:

```bash
gh repo create eks-gitops-terraform \
  --public \
  --source=. \
  --remote=origin \
  --push
```

The public repository became:

```text
bryan-obabori/eks-gitops-terraform
```

We verified:

```bash
git remote -v
git status
```

The local `main` branch was tracking `origin/main` and the working tree was clean.

---

# 17. Creating the Argo CD Application

The next step was to connect Argo CD to the Project 2 Git repository.

We created:

```text
argocd/application.yaml
```

The application was named:

```text
go-web-app
```

and stored in the `argocd` namespace.

The source configuration pointed to:

```text
repo:   bryan-obabori/eks-gitops-terraform
branch: main
path:   gitops/go-web-app-chart
```

The destination was:

```text
cluster:   https://kubernetes.default.svc
namespace: default
```

Automated sync was enabled with:

```yaml
automated:
  prune: true
  selfHeal: true
```

This commit was:

```text
a62e273  Bootstrap go web app with Argo CD
```

We pushed the commit and applied the Application object:

```bash
kubectl apply -f argocd/application.yaml
```

The first immediate `kubectl get application` displayed blank sync/health fields because reconciliation had only just started.

We did not change anything at that point; we simply rechecked.

---

# 18. Argo CD Reconciliation Succeeded

On the next check:

```bash
kubectl get application go-web-app -n argocd
```

Argo reported:

```text
SYNC STATUS   HEALTH STATUS
Synced        Healthy
```

We then verified the application resources:

```bash
kubectl get deployment,svc,ingress -n default
kubectl get pods -n default
```

Results showed:

- Deployment `1/1` available
- Service `ClusterIP`
- Ingress class `alb`
- application Pod `Running`
- AWS ALB hostname present in the Ingress status

This proved GitOps reconciliation was working.

---

# 19. First ALB Test Failed — DNS Could Not Resolve

We tried to curl the ALB hostname immediately.

The result was:

```text
curl: (6) Could not resolve host
```

Instead of changing Kubernetes or Terraform blindly, we diagnosed the load balancer state.

We checked:

```bash
aws elbv2 describe-load-balancers
```

AWS reported:

```text
Scheme: internet-facing
State:  provisioning
```

We also checked DNS with:

```bash
dig +short "$ALB"
dig +short @8.8.8.8 "$ALB"
```

Neither resolver had an answer yet.

The Kubernetes Ingress event showed:

```text
SuccessfullyReconciled
```

That combination told us the controller had successfully requested the ALB, but AWS had not finished provisioning it.

No configuration changes were made.

---

# 20. Waiting for the ALB to Become Active

We used a shell loop to query the AWS ALB state until it transitioned from:

```text
provisioning
```

to:

```text
active
```

Once active, DNS began resolving to public IPv4 addresses.

A new `curl` successfully connected to port 80.

This proved:

```text
Mac
  -> DNS
  -> public ALB
```

was now working.

---

# 21. Second ALB Test Returned HTTP 404

After DNS became available, requesting the ALB root path returned:

```text
HTTP/1.1 404 Not Found
404 page not found
```

This was an important troubleshooting moment.

Because the ALB had accepted the connection and returned an HTTP response, the infrastructure path was substantially working.

We inspected the original Go application source and found that it did not define a `/` route.

Its routes were:

```text
/home
/courses
/about
/contact
```

The Go server listens on:

```text
0.0.0.0:8080
```

So the 404 was not an ALB failure. It was the application correctly responding to an undefined route.

---

# 22. Testing the Real Application Route

We tested:

```bash
curl -I "http://$ALB/home"
```

and received:

```text
HTTP/1.1 200 OK
```

That was the first definitive end-to-end application success.

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

The application does not return success on `/`, so leaving the ALB health check on the default root path would be incorrect.

We updated the Project 2 ingress annotations to include:

```yaml
alb.ingress.kubernetes.io/healthcheck-path: /home
```

The final ingress annotations became:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/healthcheck-path: /home
```

Because the ingress manifest is in the GitOps repository, the change was committed and pushed and Argo CD reconciled it.

This aligned the ALB health check with the application's real successful route.

---

# 24. Customizing the Borrowed Application Footer

When the live application was viewed, the page still displayed the original sample author's copyright footer.

The request was to replace it with:

```text
© Bryan Obabori
```

We initially referred to the "Go files," but inspection showed the footer was not in `main.go`.

It lived in the static HTML files copied into the Docker image:

```text
static/home.html
static/about.html
static/courses.html
```

The Dockerfile copies the entire `static` directory into the runtime image.

This was another useful lesson:

```text
visible browser content
!= automatically Go source
```

The HTML source is what needed to change.

---

# 25. First Footer Automation Attempt Failed

An initial large shell block intended to:

1. modify the HTML
2. commit Project 1
3. wait for CI
4. update Project 2 image tag
5. wait for Argo
6. verify the live page

failed because a separator line was interpreted by `zsh` as a command.

The shell produced an error similar to:

```text
zsh: =========================================================== not found
```

We did not assume success.

Instead, we ran explicit verification checks.

Those checks showed:

- Project 1 HTML still contained `Abhishek.Veeramalla`
- no new CI run existed
- Project 2 still referenced the old image tag
- the live site still displayed the old footer

This was a good example of why post-change verification matters.

---

# 26. Footer Replacement Succeeded Locally, but Git Push Failed

A shorter replacement command successfully changed all matching HTML footers locally to:

```text
© Bryan Obabori
```

The change was committed in Project 1.

However, `git push` was rejected with:

```text
fetch first
```

The reason was that remote `main` contained newer commits that the local Project 1 checkout did not yet have.

Project 1's GitHub Actions workflow can itself commit updated Helm image tags, so the remote branch can move after CI.

The solution was:

```bash
git pull --rebase origin main
git push
```

This preserved the local footer commit while replaying it on top of the newer remote branch.

---

# 27. Rebuilding the Docker Image and Updating Project 2

Once the Project 1 footer commit was successfully pushed, GitHub Actions built a new Docker image.

The workflow tags images using the GitHub Actions run ID:

```text
bryanobabori/go-web-app:run-<RUN_ID>
```

After the new image was available, Project 2's Helm values were updated to point at the new immutable image tag.

That GitOps change was committed and pushed to Project 2.

Argo CD detected the repository change and updated the Kubernetes Deployment.

We then verified:

- Deployment image changed to the new `run-...` tag
- rollout completed
- live `/home` page contained `Bryan Obabori`

This exercise also demonstrated cross-repository delivery:

```text
Project 1
source code
   |
   v
GitHub Actions
   |
   v
Docker Hub image

Project 2
GitOps image tag
   |
   v
Argo CD
   |
   v
EKS Deployment
```

---

# 28. Final Application State

At completion, the application path was verified as:

```text
Argo CD:     Synced / Healthy
Deployment:  Available
Pod:         Running
Ingress:     alb
ALB:         active
/home:       HTTP 200
Footer:      © Bryan Obabori
```

The final request path is:

```text
Client
  |
  v
AWS Application Load Balancer :80
  |
  v
Kubernetes ingress rule /
  |
  v
ClusterIP Service :80
  |
  v
Pod :8080
  |
  v
Go application
```

---

# 29. Documentation Phase

After the platform was proven live, we added two repository documents.

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
- state/secrets handling
- cost warning

## TEARDOWN.md

The teardown guide was created because this project contains multiple billable AWS resources and destruction order matters.

The key order is:

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

The main reason for deleting the GitOps application first is to allow the AWS Load Balancer Controller to remove the ALB while the EKS cluster still exists.

Destroying EKS first could make external load-balancer cleanup harder.

---

# 30. Important Cost Awareness During the Lab

During the project, the live AWS environment included billable resources such as:

- EKS control plane
- two `t3.medium` EC2 worker nodes
- two NAT Gateways
- NAT Elastic IPs
- Application Load Balancer

Because the design intentionally used two NAT Gateways, this is not a zero-cost lab architecture.

The environment should be destroyed after the learning/demo session using `TEARDOWN.md`.

---

# 31. What We Reused vs What We Built New

This distinction is important when explaining the project.

## Reused from Project 1

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
Project 2 documentation and teardown process
```

This allowed the project to focus on infrastructure and platform engineering rather than wasting time rebuilding an application that had already been proven.

---

# 32. Troubleshooting Lessons from the Project

## Lesson 1 — Do not change healthy infrastructure before identifying the failing layer

When `curl` could not resolve the ALB hostname, we checked AWS ALB state and DNS first.

The ALB was simply still provisioning.

No Terraform/Kubernetes changes were needed.

## Lesson 2 — An HTTP 404 can actually prove the infrastructure works

The ALB returned `404 page not found` from the Go server.

That meant:

```text
DNS worked
TCP connection worked
ALB listener worked
routing worked
service/pod path worked
Go process responded
```

Only the requested application route was wrong.

## Lesson 3 — Inspect application routes before changing ingress rules

The Go source showed `/home` existed while `/` did not.

Testing `/home` immediately returned HTTP 200.

## Lesson 4 — Health checks should match real application behavior

The ALB health-check path was changed from the default root path to `/home`.

## Lesson 5 — Git automation can move the branch behind your local checkout

Project 1 CI commits image-tag changes back to Git.

That caused a non-fast-forward push rejection during the footer change.

The correct recovery was a rebase, not a force push:

```bash
git pull --rebase origin main
git push
```

## Lesson 6 — Verify after automation

The first large footer script failed partway through.

Explicit checks prevented us from mistakenly believing the live app had changed.

## Lesson 7 — Keep account-specific values out of the public repository

The EKS API allow-list CIDR was moved into ignored `terraform.tfvars` before the first push.

## Lesson 8 — Terraform syntax is not the hardest part

Much of the complexity in this project came from the actual AWS/EKS architecture:

- routing
- NAT
- IAM
- EKS control-plane requirements
- private nodes
- Pod Identity
- Kubernetes provider authentication
- load-balancer integration

Tools such as `eksctl` hide many of these details. Terraform made them explicit.

---

# 33. Useful Verification Commands

## Infrastructure / nodes

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

# 34. Terraform Commands Used Most Often

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

# 35. Final Architecture Summary

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

# 36. How to Explain This Project in an Interview

A concise explanation:

> I rebuilt an EKS application platform with Terraform rather than relying on `eksctl`. I explicitly provisioned the VPC, public and private subnets, NAT gateways, routing, EKS control plane, IAM roles, and a private managed node group across two Availability Zones. I separated the Kubernetes platform components into a second Terraform root module, installed Argo CD and AWS Load Balancer Controller with Helm, and used EKS Pod Identity to give the controller dedicated AWS permissions. I then reused a proven Helm chart, converted its ingress to AWS ALB, and used an Argo CD Application with automated sync, prune, and self-heal to deploy it from Git. I verified the whole path through an internet-facing ALB and debugged DNS provisioning, an application-level 404, and the ALB health-check path.

Key tradeoffs that can be discussed:

- two NAT Gateways vs one cheaper NAT Gateway
- private nodes vs public nodes
- Pod Identity vs broad worker-node permissions
- separate Terraform states vs one giant state
- ALB ingress vs ingress-nginx
- GitOps reconciliation vs direct `kubectl apply`
- local Terraform state for a lab vs remote state for a shared production environment

---

# 37. Project Completion State

Project 2 is considered complete when all of the following are true:

```text
[✓] Terraform network applied
[✓] EKS cluster applied
[✓] two private worker nodes Ready
[✓] Argo CD installed
[✓] Pod Identity Agent installed
[✓] AWS Load Balancer Controller installed
[✓] Helm chart stored in Project 2 GitOps path
[✓] Argo CD Application bootstrapped
[✓] Argo reports Synced / Healthy
[✓] application Pod Running
[✓] internet-facing ALB Active
[✓] /home returns HTTP 200
[✓] ALB health check uses /home
[✓] website footer customized
[✓] README written
[✓] teardown guide written
[✓] build journal written
```

The only lifecycle step intentionally left for later is destruction of the live AWS lab environment.

Follow `TEARDOWN.md` when that time comes.
