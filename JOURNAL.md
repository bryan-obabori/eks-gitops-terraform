# Project 2 Build Journal — Terraform EKS GitOps Platform

This journal records how Project 2 evolved from a Terraform-focused EKS platform into a self-contained application delivery project with its own Go application source, GitHub Actions CI pipeline, GitOps configuration, Terraform-managed platform, Argo CD, and AWS ALB ingress.

The `README.md` is the operational source of truth for how to build, run, release, and destroy the environment. This journal preserves the chronological story: what was built first, what problems appeared, what changed, and why.

---

# 1. Starting Point

Project 1 had already proven a complete basic DevOps delivery path using:

- Go
- Docker
- GitHub Actions
- Kubernetes
- EKS
- Helm
- Argo CD
- GitOps

Its EKS environment was created primarily with `eksctl`, which was useful for getting a working cluster quickly but hid many of the AWS relationships that exist underneath EKS.

Project 2 was created to rebuild that same general delivery idea with more explicit infrastructure ownership and more production-oriented AWS patterns.

The central question became:

> What does `eksctl` create for us, and how can we model those relationships ourselves with Terraform?

---

# 2. Original Target Architecture

The original target architecture was:

```text
Terraform
   |
   +--> AWS VPC / subnets / routing / NAT
   +--> EKS control plane + private worker nodes
   +--> IAM
   +--> Argo CD
   +--> AWS Load Balancer Controller
   |
   v
GitOps configuration
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

At the beginning, the application image and Helm ideas were reused from Project 1 so the focus could remain on Terraform, AWS networking, EKS, IAM, and GitOps infrastructure.

This later changed. Once the infrastructure worked, Project 2 was made fully self-contained by adding its own application source and CI pipeline.

---

# 3. Terraform Root-Module Model

One of the most important concepts established early was that Terraform reads all `.tf` files in the same directory as one root module.

The project initially used two Terraform roots:

```text
terraform/infra
terraform/platform
```

Later, a third was added:

```text
terraform/apps
```

The resulting lifecycle boundaries are:

```text
infra
  = VPC + networking + EKS + workers + core IAM

platform
  = Argo CD + Pod Identity + AWS Load Balancer Controller

apps
  = Argo CD Application bootstrap object
```

Each root module has its own Terraform state because each layer has a different dependency and lifecycle boundary.

---

# 4. Building the AWS Network

The network was modeled explicitly rather than hidden behind a cluster-creation helper.

The VPC design is:

```text
VPC 10.0.0.0/16

AZ A
├── Public subnet  10.0.1.0/24
└── Private subnet 10.0.11.0/24

AZ B
├── Public subnet  10.0.2.0/24
└── Private subnet 10.0.12.0/24
```

Terraform queries available Availability Zones instead of hard-coding specific AZ names.

The public subnets are tagged for external load-balancer discovery:

```hcl
"kubernetes.io/role/elb" = "1"
```

The private subnets are tagged for internal load-balancer discovery:

```hcl
"kubernetes.io/role/internal-elb" = "1"
```

The VPC includes:

- Internet Gateway
- two NAT Gateways
- two Elastic IPs
- public route table
- one private route table per AZ

Routing is:

```text
Public route table
0.0.0.0/0 -> Internet Gateway

Private route table A
0.0.0.0/0 -> NAT Gateway A

Private route table B
0.0.0.0/0 -> NAT Gateway B
```

The two-NAT design costs more than a single-NAT lab but demonstrates AZ-independent private-subnet egress.

---

# 5. Adding EKS

The EKS cluster is:

```text
go-web-app-cluster
```

The cluster was configured for Kubernetes/EKS version:

```text
1.35
```

Authentication mode:

```text
API_AND_CONFIG_MAP
```

The control-plane endpoint supports both private and public access, while public API access is restricted to an administrator `/32` CIDR.

A dedicated EKS control-plane IAM role was created and attached to the required EKS cluster policy.

---

# 6. Keeping Environment-Specific IP Data Out of Git

The EKS public API allow list was moved into an input variable:

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

That file is ignored by Git.

This kept environment-specific public IP data out of the public repository while still allowing Terraform to own the EKS endpoint configuration.

---

# 7. Managed Worker Nodes

The managed node group uses a separate IAM role with the worker-node, ECR-pull, and CNI permissions required by EKS.

The worker configuration is:

```text
instance type: t3.medium
capacity type: ON_DEMAND
minimum:       2
desired:       2
maximum:       3
```

Workers run only in private subnets and do not receive public IP addresses.

This made the topology materially different from a basic lab cluster whose nodes are directly exposed to the internet.

---

# 8. Creating the Platform Layer

A separate Terraform root was created at:

```text
terraform/platform
```

It uses AWS, Kubernetes, Helm, and HTTP providers.

Terraform queries the existing EKS cluster and configures Kubernetes/Helm access using:

- EKS endpoint
- cluster CA certificate
- EKS authentication token

This avoids hard-coded Kubernetes credentials.

---

# 9. Installing Argo CD

Argo CD was installed through Terraform and Helm into:

```text
argocd
```

The Argo CD server Service remained:

```text
ClusterIP
```

The UI was not exposed publicly.

The goal was to use Argo CD as the continuous reconciler for the application while keeping Terraform responsible for platform installation.

---

# 10. Choosing AWS Load Balancer Controller

Project 2 intentionally moved away from the ingress pattern used in Project 1 and adopted AWS Load Balancer Controller.

The traffic path became:

```text
Internet
   |
   v
AWS ALB
   |
   v
Kubernetes Ingress
   |
   v
ClusterIP Service
   |
   v
Pod
```

The controller is responsible for translating the Kubernetes Ingress into AWS load-balancer resources.

---

# 11. EKS Pod Identity for the Controller

The AWS Load Balancer Controller requires AWS permissions for resources such as:

- ALBs
- target groups
- listeners
- security groups

Instead of adding those permissions broadly to the worker-node role, Project 2 uses EKS Pod Identity.

Terraform installs:

```text
eks-pod-identity-agent
```

and creates:

- dedicated controller IAM policy
- dedicated controller IAM role
- Kubernetes service account
- Pod Identity association

The controller therefore receives AWS permissions through a dedicated workload identity.

---

# 12. Reusing the Known-Working Application Chart

The known-working Helm structure from Project 1 was initially reused in Project 2.

Project 2 stores the active GitOps chart at:

```text
gitops/go-web-app-chart
```

The chart contains:

- Deployment
- ClusterIP Service
- Ingress
- image configuration

The application image repository remained:

```text
bryanobabori/go-web-app
```

The container listens on port `8080`; the Service exposes port `80` and forwards traffic to the container.

---

# 13. Converting Ingress to AWS ALB

The Ingress was changed to use:

```yaml
spec:
  ingressClassName: alb
```

with annotations including:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
```

The Service remains `ClusterIP` because ALB IP target mode registers pod IPs rather than requiring a public NodePort path.

---

# 14. Publishing the Repository Safely

Before publishing, `.gitignore` excluded items such as:

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

The repository also avoids publishing:

- local home paths
- public administrator IPs
- AWS account IDs
- credentials
- tokens
- ephemeral ALB identifiers

---

# 15. Initial Argo CD Application Bootstrap

The Argo CD Application manifest lives at:

```text
argocd/application.yaml
```

It points to:

```text
repository: bryan-obabori/eks-gitops-terraform
revision:   main
path:       gitops/go-web-app-chart
```

with automated reconciliation enabled:

```yaml
automated:
  prune: true
  selfHeal: true
```

At this stage, the Application was first bootstrapped manually using `kubectl`.

That was later improved so Terraform owns the bootstrap object as well.

---

# 16. Argo CD Reconciliation

After the Application was created, Argo CD reconciled the Helm chart and reported:

```text
Synced
Healthy
```

The cluster contained:

- Deployment
- application pod
- ClusterIP Service
- ALB Ingress

This proved the Git-to-Argo-to-Kubernetes path worked.

---

# 17. ALB DNS Troubleshooting

The first request to the generated ALB hostname failed because DNS was not yet available.

Instead of changing Terraform or Kubernetes immediately, AWS state was checked.

The ALB was still:

```text
provisioning
```

The correct diagnosis was simply that AWS had not finished creating the load balancer and DNS record.

No configuration change was required.

---

# 18. ALB Becomes Active

Once the ALB changed to:

```text
active
```

DNS resolved and traffic reached the application.

That validated:

```text
Internet
  -> ALB
  -> Service
  -> Pod
```

---

# 19. Diagnosing HTTP 404 Correctly

The root URL returned:

```text
HTTP/1.1 404 Not Found
```

This was not an infrastructure failure.

The Go application defines:

```text
/home
/courses
/about
/contact
```

but intentionally has no `/` route.

The 404 therefore proved that:

- DNS worked
- the ALB worked
- Kubernetes routing worked
- the Service worked
- the pod worked
- the Go server worked

The wrong application route was being requested.

---

# 20. Verifying the Correct Application Route

Testing:

```text
/home
```

returned:

```text
HTTP/1.1 200 OK
```

This became the correct end-to-end application check.

---

# 21. Fixing the ALB Health Check

Because `/` does not return success, the Ingress was updated with:

```yaml
alb.ingress.kubernetes.io/healthcheck-path: /home
```

The final important ALB annotations became:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/healthcheck-path: /home
```

Argo CD reconciled this change automatically from Git.

---

# 22. Tightening Terraform Ownership

After the platform was working, the ownership model was reviewed.

Terraform already managed:

```text
VPC
EKS
worker nodes
Argo CD
AWS Load Balancer Controller
Pod Identity
```

but the Argo CD Application itself had originally been created manually.

That left one bootstrap object outside Terraform state.

The design goal was tightened:

> Terraform should own the infrastructure and bootstrap boundary; Argo CD should own workload reconciliation.

---

# 23. Adding `terraform/apps`

A third Terraform root was created:

```text
terraform/apps
```

It manages the Argo CD Application using `kubernetes_manifest`.

The Application also includes the Argo cascading-resource finalizer:

```yaml
finalizers:
  - resources-finalizer.argocd.argoproj.io
```

This matters during destruction because the workload needs to disappear before the controllers and EKS cluster disappear.

---

# 24. Importing the Existing Application

Because the Argo Application already existed, it was imported into Terraform instead of being deleted and recreated.

The import preserved the live workload while bringing the bootstrap object under Terraform ownership.

After the transition:

```text
Argo Application: Synced / Healthy
Deployment:       1/1
Ingress:          active
```

There was no intentional application recreation or downtime.

---

# 25. Final Infrastructure Ownership Model

The infrastructure/platform design became:

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
            |
            v
         Argo CD
            ├── Deployment
            ├── Service
            └── Ingress
                    |
                    v
          AWS Load Balancer Controller
                    |
                    v
                   ALB
```

This avoids dual ownership of Deployment, Service, and Ingress between Terraform and Argo CD.

---

# 26. Final Start Order

The rebuild sequence is:

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

The order exists because later layers depend on APIs and resources created by earlier layers.

---

# 27. Final Destroy Order

Destruction must happen in reverse ownership order:

```text
terraform/apps destroy
        |
        v
Argo CD deletes Deployment / Service / Ingress
        |
        v
AWS Load Balancer Controller deletes ALB
        |
        v
terraform/platform destroy
        |
        v
terraform/infra destroy
```

Destroying EKS first would remove the controllers and Kubernetes API before they could clean up the resources they own.

---

# 28. Reassessing the Application Boundary

After the infrastructure work was complete, Project 2 was reviewed as a portfolio project.

At that point, the project still depended conceptually on Project 1 for application source and image creation.

That created unnecessary coupling:

```text
Project 1
   -> application source
   -> Docker image

Project 2
   -> Terraform
   -> GitOps
   -> deployment
```

A cross-repository CI/CD bridge was considered, but that would have introduced extra tokens, permissions, and repository coordination for little learning value.

The simpler design was better:

> Project 2 should be a standalone, improved version of Project 1.

---

# 29. Making Project 2 Self-Contained

The working Go application was copied into:

```text
app/
```

The directory now contains:

```text
app/
├── Dockerfile
├── go.mod
├── main.go
├── main_test.go
└── static/
    ├── about.html
    ├── contact.html
    ├── courses.html
    ├── home.html
    └── images/
```

Only the application source was carried over. Project 1 infrastructure, Helm, Argo, and Terraform content were not duplicated because Project 2 already had improved versions of those components.

---

# 30. Verifying the Application Before CI

Before connecting the application to the delivery pipeline, the app was tested independently.

Local Go validation succeeded:

```text
go test ./...  -> passed
```

The application also built successfully.

A local Docker image was then built explicitly for:

```text
linux/amd64
```

This was important because the development laptop uses Apple Silicon while the EKS worker nodes use amd64.

The Docker build completed successfully, proving the application could be packaged correctly before involving GitHub Actions or Argo CD.

---

# 31. Adding Project 2 GitHub Actions CI

A new workflow was added at:

```text
.github/workflows/ci.yaml
```

The workflow triggers on changes to:

```text
app/**
.github/workflows/ci.yaml
```

The CI flow is:

```text
checkout
   |
   v
setup Go
   |
   v
go test
   |
   v
go build
   |
   v
Docker Buildx
   |
   v
Docker Hub login
   |
   v
build + push linux/amd64 image
```

Images use immutable run-specific tags:

```text
bryanobabori/go-web-app:run-<GITHUB_RUN_ID>
```

This avoids relying on a mutable `latest` tag and makes each deployment traceable to a specific workflow run.

---

# 32. Connecting CI Directly to GitOps

After a successful Docker push, the same workflow updates:

```text
gitops/go-web-app-chart/values.yaml
```

with the newly built image tag.

The workflow then commits the GitOps change back to the same repository.

The application release path is now:

```text
Developer changes app/
        |
        v
GitHub Actions
        |
        v
Test + build
        |
        v
Docker Hub
        |
        v
GitOps values.yaml update
        |
        v
Git commit
        |
        v
Argo CD
        |
        v
Kubernetes rollout
```

No cross-repository credential or synchronization layer is needed.

---

# 33. Preventing a CI Loop

The workflow commits a new image tag into the GitOps chart.

To prevent that bot-generated commit from retriggering the same CI pipeline, the workflow is scoped only to:

```text
app/**
.github/workflows/ci.yaml
```

The generated GitOps commit changes only:

```text
gitops/go-web-app-chart/values.yaml
```

so it does not satisfy the workflow path filter.

This keeps the delivery flow deterministic rather than recursive.

---

# 34. Fixing Go Cache Discovery After Moving the Module

Once `go.mod` lived under `app/`, GitHub Actions emitted a cache warning because the default dependency lookup expected a root-level module file.

The workflow already used:

```yaml
go-version-file: app/go.mod
```

but caching also needed an explicit path:

```yaml
cache-dependency-path: app/go.mod
```

That change aligned the cache behavior with the new repository structure.

---

# 35. Final Repository Architecture

The final repository is now:

```text
eks-gitops-terraform/
│
├── app/
│   ├── Dockerfile
│   ├── go.mod
│   ├── main.go
│   ├── main_test.go
│   └── static/
│
├── .github/
│   └── workflows/
│       └── ci.yaml
│
├── gitops/
│   └── go-web-app-chart/
│
├── argocd/
│   └── application.yaml
│
├── terraform/
│   ├── infra/
│   ├── platform/
│   └── apps/
│
├── README.md
├── JOURNAL.md
└── ABOUT.md
```

The project is now self-contained.

---

# 36. Final Source-to-Platform Flow

The complete application delivery flow is:

```text
Application source
      |
      v
GitHub Actions
      |
      +--> test
      +--> build
      +--> Docker image
      |
      v
Docker Hub
      |
      v
GitOps image tag
      |
      v
Argo CD
      |
      v
Kubernetes
      |
      v
AWS ALB
      |
      v
User
```

Terraform provides the platform underneath that flow:

```text
Terraform
   -> AWS networking
   -> EKS
   -> IAM
   -> Pod Identity
   -> Argo CD
   -> AWS Load Balancer Controller
   -> Argo Application bootstrap
```

---

# 37. Project 1 vs Project 2

The clearest way to describe the progression is:

```text
PROJECT 1
Basic working DevOps pipeline

Go
Docker
GitHub Actions
EKS via eksctl
Helm
Argo CD
NGINX ingress
GitOps
```

Project 2 keeps the same application-delivery idea but improves the implementation:

```text
PROJECT 2
Improved production-style rebuild

Go app included in repository
GitHub Actions CI
immutable Docker tags
Terraform-managed VPC
private worker nodes
explicit routing and NAT
EKS IAM
Pod Identity
AWS Load Balancer Controller
ALB
Terraform-managed Argo bootstrap
Argo CD GitOps
ordered Terraform lifecycle
```

Project 2 is therefore not a separate random tutorial. It is the deliberate evolution of Project 1.

---

# 38. Key Lessons

The project reinforced several core DevOps and platform-engineering ideas:

- Infrastructure convenience tools can hide relationships that become much clearer when modeled explicitly with Terraform.
- Terraform state defines what a Terraform root owns; it does not automatically know about all resources in the environment.
- Platform infrastructure and application workloads should have clear ownership boundaries.
- Terraform can bootstrap Argo CD without also competing with Argo CD for workload ownership.
- Kubernetes Ingress describes desired routing; AWS Load Balancer Controller turns that intent into actual AWS ALB resources.
- Pod Identity gives Kubernetes workloads dedicated AWS identities instead of relying on broad node permissions.
- A `404` can prove that the infrastructure path works when the application route itself is wrong.
- Immutable container tags make deployments traceable.
- A self-contained repository is often the clearest portfolio architecture when the goal is to demonstrate the complete source-to-platform lifecycle.
- Local development architecture and target runtime architecture matter; Apple Silicon builds should not accidentally produce images incompatible with amd64 workers.
- Application CI and infrastructure Terraform do not have to run together. Normal application releases can flow through GitHub Actions and Argo CD without reapplying Terraform.
- Start and destroy order matter when controllers own downstream cloud resources.

---

# 39. Final Outcome

Project 2 now demonstrates a complete, self-contained DevOps platform:

```text
Go application
+ tests
+ GitHub Actions
+ Docker
+ Docker Hub
+ Terraform
+ AWS networking
+ EKS
+ IAM
+ EKS Pod Identity
+ Helm
+ Argo CD
+ Terraform-managed Argo Application
+ GitOps
+ Kubernetes
+ AWS Load Balancer Controller
+ Application Load Balancer
```

The simplest summary is:

> Project 1 proved the pipeline. Project 2 rebuilt and improved the entire application platform with explicit Terraform-managed AWS infrastructure, private EKS workers, AWS-native ingress, dedicated workload identity, and a self-contained CI/GitOps delivery workflow.
