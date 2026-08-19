# Terraform EKS GitOps Teardown Guide

This guide removes the live AWS and Kubernetes resources created by this project without leaving common billable resources behind.

> **Warning**
>
> These commands are destructive. They remove the live application, Application Load Balancer, Argo CD, AWS Load Balancer Controller, EKS worker nodes, EKS control plane, NAT Gateways, Elastic IPs, subnets, route tables, and VPC resources managed by this project.
>
> The GitHub repositories and Docker Hub images are not deleted.

## Environment

```text
AWS region:        us-east-1
EKS cluster:       go-web-app-cluster
Application:       go-web-app
Argo namespace:    argocd
Application NS:    default
Ingress class:     alb
```

## Destruction Order

The order matters because the Kubernetes ingress owns an AWS Application Load Balancer outside the cluster.

```text
Argo CD Application
        |
        v
Application Deployment / Service / Ingress
        |
        v
AWS Application Load Balancer
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

Do not destroy EKS first. If the cluster disappears before Kubernetes controllers remove the ALB, cleanup becomes harder and can leave billable AWS resources behind.

---

## 1. Move to the Project Root

```bash
cd /Users/bryanobabori/Documents/go-web-app/eks-gitops-terraform
```

Confirm the expected cluster is active before doing anything destructive:

```bash
kubectl config current-context
kubectl get nodes
kubectl get application go-web-app -n argocd
```

---

## 2. Capture the ALB Before Deletion

Save the current hostname so it can be checked after cleanup:

```bash
ALB_DNS=$(kubectl get ingress go-web-app \
  -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB to remove: $ALB_DNS"
```

Optionally confirm AWS currently sees it:

```bash
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}" \
  --output table
```

---

## 3. Delete the Argo CD Application With Cascading Cleanup

Argo CD has automated sync and self-heal enabled. Deleting the Kubernetes resources directly while the Argo CD Application still exists can cause Argo to recreate them.

Ensure the Application has the Argo CD resource finalizer, then delete it:

```bash
kubectl patch application go-web-app \
  -n argocd \
  --type merge \
  -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'

kubectl delete application go-web-app -n argocd
```

Verify the application resources are disappearing:

```bash
kubectl get deployment,svc,ingress -n default
```

The built-in Kubernetes service can remain:

```text
service/kubernetes
```

Do **not** continue until `ingress/go-web-app` is gone.

---

## 4. Verify the AWS ALB Is Deleted

After the Ingress disappears, verify that its AWS load balancer is no longer present:

```bash
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].[LoadBalancerName,State.Code]" \
  --output table
```

Expected result:

```text
<no rows>
```

If the ALB still exists, inspect the AWS Load Balancer Controller before destroying the platform or cluster:

```bash
kubectl logs -n kube-system \
  deployment/aws-load-balancer-controller \
  --tail=100
```

Also check Kubernetes events:

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -40
```

---

## 5. Destroy the Terraform Platform Layer

The platform root module manages Argo CD, the AWS Load Balancer Controller, Pod Identity resources, the controller IAM resources, and the EKS Pod Identity Agent add-on.

Run:

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/platform apply destroy.tfplan
```

Expected high-level result:

```text
Argo CD removed
AWS Load Balancer Controller removed
Pod Identity association removed
Controller IAM role/policy removed
Pod Identity Agent add-on removed
```

Verify the platform namespaces/components are gone or no longer contain the project resources:

```bash
kubectl get pods -n argocd 2>/dev/null || true
kubectl get pods -n kube-system | grep -E 'aws-load-balancer-controller|eks-pod-identity-agent' || true
```

---

## 6. Confirm the Infra Variable File Still Exists

The infrastructure module requires `allowed_public_cidr`.

Because `terraform.tfvars` is intentionally ignored by Git, confirm the local file is still present before running destroy:

```bash
cat terraform/infra/terraform.tfvars
```

It should contain a valid value similar to:

```hcl
allowed_public_cidr = "YOUR_CURRENT_PUBLIC_IP/32"
```

The exact value does not need to match the original address for resource destruction; Terraform only needs the required variable to be supplied so it can load the configuration and state.

If the file no longer exists, recreate it before continuing.

---

## 7. Destroy the Terraform Infrastructure Layer

The infrastructure root module owns the EKS cluster, managed node group, VPC networking, NAT Gateways, route tables, IAM roles, and related resources.

Create and apply a saved destroy plan:

```bash
terraform -chdir=terraform/infra init
terraform -chdir=terraform/infra plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/infra apply destroy.tfplan
```

Terraform should remove the dependency graph in the required order, including:

```text
EKS managed node group
        |
        v
EKS control plane
        |
        v
NAT Gateways / Elastic IPs
        |
        v
Subnets / route tables
        |
        v
Internet Gateway
        |
        v
VPC
```

Do not delete individual Terraform-managed AWS resources manually unless Terraform reports a specific failure that requires intervention.

---

## 8. Verify EKS Is Gone

```bash
aws eks list-clusters \
  --region us-east-1 \
  --query "clusters[?@=='go-web-app-cluster']"
```

Expected:

```json
[]
```

---

## 9. Verify the Worker Nodes Are Gone

```bash
aws ec2 describe-instances \
  --region us-east-1 \
  --filters \
    "Name=tag:aws:eks:cluster-name,Values=go-web-app-cluster" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].{Instance:InstanceId,State:State.Name,Type:InstanceType}" \
  --output table
```

Expected:

```text
<no rows>
```

---

## 10. Verify the Application Load Balancer Is Gone

Use the hostname captured earlier:

```bash
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].[LoadBalancerName,State.Code]" \
  --output table
```

Expected:

```text
<no rows>
```

---

## 11. Verify NAT Gateways Are Gone

NAT Gateways are independently billable and should be checked explicitly.

```bash
aws ec2 describe-nat-gateways \
  --region us-east-1 \
  --filter "Name=state,Values=pending,available" \
  --query "NatGateways[].{NAT:NatGatewayId,State:State,VPC:VpcId}" \
  --output table
```

If this AWS account contains other environments, do not assume every returned NAT Gateway belongs to this project. Match any result to the VPC from the Terraform state or previous outputs before deleting anything manually.

For an account containing only this lab, expected output is:

```text
<no rows>
```

---

## 12. Verify Elastic IP Addresses

The two NAT Gateways use Elastic IP addresses. After Terraform destroys the NAT Gateways and their EIPs, review any remaining addresses:

```bash
aws ec2 describe-addresses \
  --region us-east-1 \
  --query "Addresses[].{PublicIP:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId}" \
  --output table
```

Do not release unrelated Elastic IPs if this account hosts other environments.

---

## 13. Verify Unattached EBS Volumes

```bash
aws ec2 describe-volumes \
  --region us-east-1 \
  --filters "Name=status,Values=available" \
  --query "Volumes[].{Volume:VolumeId,SizeGiB:Size,State:State}" \
  --output table
```

An `available` EBS volume is unattached and can still incur storage charges.

Do not blindly delete volumes in a shared AWS account.

---

## 14. Verify Terraform State Is Empty

Check both local root modules:

```bash
echo "===== PLATFORM STATE ====="
terraform -chdir=terraform/platform state list

echo "===== INFRA STATE ====="
terraform -chdir=terraform/infra state list
```

A fully destroyed environment should return no managed resources from either state.

Keep the state files locally if you want the teardown history. They are ignored by Git and should not be committed.

---

## 15. Final Read-Only Verification

Run this after both Terraform destroys complete:

```bash
echo "===== EKS CLUSTER ====="
aws eks list-clusters \
  --region us-east-1 \
  --query "clusters[?@=='go-web-app-cluster']"

echo "===== EKS EC2 NODES ====="
aws ec2 describe-instances \
  --region us-east-1 \
  --filters \
    "Name=tag:aws:eks:cluster-name,Values=go-web-app-cluster" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].{Instance:InstanceId,State:State.Name,Type:InstanceType}" \
  --output table

echo "===== OLD ALB ====="
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].[LoadBalancerName,State.Code]" \
  --output table

echo "===== ACTIVE NAT GATEWAYS ====="
aws ec2 describe-nat-gateways \
  --region us-east-1 \
  --filter "Name=state,Values=pending,available" \
  --query "NatGateways[].{NAT:NatGatewayId,State:State,VPC:VpcId}" \
  --output table

echo "===== ELASTIC IPS ====="
aws ec2 describe-addresses \
  --region us-east-1 \
  --query "Addresses[].{PublicIP:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId}" \
  --output table

echo "===== UNATTACHED EBS ====="
aws ec2 describe-volumes \
  --region us-east-1 \
  --filters "Name=status,Values=available" \
  --query "Volumes[].{Volume:VolumeId,SizeGiB:Size,State:State}" \
  --output table

echo "===== TERRAFORM PLATFORM STATE ====="
terraform -chdir=terraform/platform state list

echo "===== TERRAFORM INFRA STATE ====="
terraform -chdir=terraform/infra state list
```

Interpret shared-account results carefully. The important result is that resources belonging to this project are absent.

---

## What Remains After Teardown

The teardown removes the live AWS environment but leaves the project artifacts intact:

```text
GitHub
├── Terraform configuration
├── Argo CD Application manifest
├── Helm chart
├── README
└── teardown documentation

Docker Hub
└── previously built application images

Local machine
└── ignored Terraform state / tfvars files unless manually removed
```

The environment can therefore be rebuilt from source later.

## Rebuild Order

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
kubectl apply -f argocd/application.yaml
        |
        v
Argo CD deploys application from Git
```
