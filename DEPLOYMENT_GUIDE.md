# Deployment Guide: Karpenter + KEDA GPU Inference on EKS

Complete step-by-step walkthrough for deploying the GPU inference autoscaling stack.

---

## Prerequisites Checklist

- [ ] AWS Account (with GPU quota: see AWS Service Quotas console)
- [ ] IAM credentials configured: `aws sts get-caller-identity`
- [ ] `terraform` installed: `terraform version`
- [ ] `kubectl` installed: `kubectl version --client`
- [ ] `aws-cli` v2: `aws --version`
- [ ] `helm` installed: `helm version`
- [ ] GitHub personal access token (for private repos)

---

## Phase 1: Infrastructure Provisioning (Terraform)

### 1.1 Initialize Terraform

```bash
cd terraform

# Initialize Terraform backend & download AWS provider
terraform init

# Validate config
terraform validate

# See what will be created
terraform plan -var-file="environments/dev.tfvars"
```

**Expected output**: ~30 resources to create (VPC, EKS, IAM, endpoints, etc.)

### 1.2 Deploy Infrastructure

```bash
# Apply the Terraform plan
terraform apply -var-file="environments/dev.tfvars"

# This takes ~15-20 minutes
# ✅ Once complete, you'll see:
# Apply complete! Resources created: 30
```

### 1.3 Export Terraform Outputs

```bash
# Save outputs for next steps
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export AWS_REGION=$(terraform output -raw aws_region)
export KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_role_arn)

# Verify
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Karpenter Role: $KARPENTER_ROLE_ARN"
```

### 1.4 Verify EKS Cluster

```bash
# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Verify connectivity
kubectl get nodes
# ✅ Expected: 1 t3.medium node (managed group)

# Check system pods
kubectl get pods -n kube-system
```

---

## Phase 2: Argo CD Installation

### 2.1 Install Argo CD

```bash
# Create namespace
kubectl create namespace argocd

# Install from official manifests
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for deployment
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s
```

### 2.2 Verify Argo CD

```bash
# Check pods
kubectl get pods -n argocd

# Port-forward to Argo CD server (dev only)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Get initial admin password
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d)

echo "Argo CD URL: https://localhost:8080"
echo "Admin password: $ARGOCD_PASSWORD"
```

---

## Phase 3: GitHub Repository Setup

### 3.1 Fork This Repository

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/karpenter-keda-gpu-inference-demo.git
cd karpenter-keda-gpu-inference-demo

# (Or if you own the repo already, just clone normally)
```

### 3.2 Update Repository Reference in ArgoCD Manifests

```bash
# Edit app-of-apps.yaml
# Change:
#   repoURL: https://github.com/YOUR_ORG/karpenter-keda-gpu-inference-demo

# If using private repo, create GitHub secret:
kubectl create secret generic github-credentials \
  -n argocd \
  --from-literal=username=YOUR_USERNAME \
  --from-literal=password=YOUR_GITHUB_TOKEN

# Then update argocd/app-of-apps.yaml to reference it
```

---

## Phase 4: Deploy GitOps Stack (ArgoCD)

### 4.1 Update Karpenter IAM Role in Values

```bash
# Edit environments/dev/values/karpenter-values.yaml
# Update:
#   eks.amazonaws.com/role-arn: $KARPENTER_ROLE_ARN

sed -i "s|ACCOUNT_ID|$(aws sts get-caller-identity --query Account --output text)|g" \
  environments/dev/values/karpenter-values.yaml
```

### 4.2 Deploy Root Application

```bash
# Apply the root Application (orchestrates everything)
kubectl apply -f argocd/app-of-apps.yaml

# Monitor progress
kubectl get application -n argocd --watch

# Detailed sync status
argocd app get root -n argocd
```

### 4.3 Watch Argo CD Sync

```bash
# Watch as components deploy (wave 0: parallel)
# Then inference pods (wave 1: after platform ready)

argocd app sync root --prune

# Monitor logs
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter
kubectl logs -f -n keda -l app=keda-operator
```

**Timeline:**
- Wave 0 (parallel): Karpenter, KEDA, Prometheus (5-10 min)
- Wave 1 (after wave 0): Inference pods (2-3 min)
- **Total**: ~15 minutes

### 4.4 Verify Platform Deployment

```bash
# ✅ Karpenter
kubectl get nodepools -n karpenter
kubectl describe nodepool gpu -n karpenter

# ✅ KEDA
kubectl get scaledobject
kubectl describe scaledobject inference-scaler -n default

# ✅ Prometheus
kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &

# ✅ Knative Serving
kubectl get pods -n knative-serving

# ✅ Inference pods
kubectl get pods -l app=inference-pod
kubectl logs -l app=inference-pod
```

---

## Phase 5: Testing & Validation

### 5.1 Trigger GPU Node Scaling

GPU nodes scale when inference pods are requested. Since the demo pod requests GPU:

```bash
# Check if GPU node is launching
watch kubectl get nodes -L kubernetes.io/instance-type

# Or check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100

# Check node status
AWS_REGION=eu-west-2
aws ec2 describe-instances --region $AWS_REGION \
  --filters "Name=tag:karpenter.sh/do-not-evict,Values=false" \
  --query 'Reservations[].Instances[].{Type:InstanceType,ID:InstanceId,State:State.Name}'
```

### 5.2 Monitor Pod Autoscaling (KEDA)

```bash
# Check ScaledObject
kubectl describe scaledobject inference-scaler

# Monitor pod count as queue grows
watch kubectl get pods -l app=inference-pod

# Check KEDA metrics
kubectl port-forward -n keda svc/keda-operator 8080:8080 &
curl http://localhost:8080/metrics | grep keda
```

### 5.3 Verify Prometheus Metrics

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &

# Visit http://localhost:9090
# Query: up{job="karpenter"}  # Should return 1 (healthy)
# Query: karpenter_nodes_allocatable  # Should see node count
```

### 5.4 Access Grafana

```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &

# Visit http://localhost:3000
# User: admin
# Password: (check environments/dev/values/prometheus-values.yaml)

# Explore pre-built dashboards
```

---

## Phase 6: Multi-Environment Setup (Optional)

### 6.1 Deploy to Staging

```bash
# Create new EKS cluster
cd terraform
terraform apply -var-file="environments/staging.tfvars"

# Get staging cluster info
export STAGING_CLUSTER=$(terraform output cluster_name)
aws eks update-kubeconfig --name $STAGING_CLUSTER --region $AWS_REGION

# Install Argo CD on staging cluster
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Deploy from staging values
kubectl apply -f argocd/app-of-apps.yaml

# (Argo CD will use environments/staging/values/ automatically)
```

### 6.2 Deploy to Production

**Same as staging, but:**

1. Use `terraform apply -var-file="environments/production.tfvars"`
2. Switch manual sync: Edit `argocd/app-of-apps.yaml`:
   ```yaml
   syncPolicy:
     automated:
       prune: false  # MANUAL SYNC in production
       selfHeal: false
   ```
3. Pin to a git tag (not `main`):
   ```yaml
   source:
     targetRevision: v1.0.0  # Instead of main
   ```
4. Require PR approvals before deployments
5. Add SQS queue for spot interruption handling

---

## Troubleshooting

### Cluster Creation Fails

```bash
# Check Terraform errors
terraform validate

# Check AWS quotas
aws service-quotas list-service-quotas --service-code ec2 \
  | grep GPU

# If insufficient quota, request increase in AWS console
```

### Karpenter Not Provisioning Nodes

```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Check IAM permissions
aws iam get-role-policy --role-name eks-gpu-cluster-karpenter-role \
  --policy-name karpenter-policy

# Check NodePool status
kubectl describe nodepool gpu -n karpenter
```

### KEDA Pods Not Scaling

```bash
# Check ScaledObject errors
kubectl describe scaledobject inference-scaler

# Verify Prometheus query
kubectl exec -it -n monitoring prometheus-pod -- \
  curl "http://localhost:9090/api/v1/query?query=gpu_queue_depth"

# Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator
```

### Inference Pod Stuck in Pending

```bash
# Check node affinity
kubectl describe pod -l app=inference-pod

# Check if GPU node launched
kubectl get nodes -L nvidia.com/gpu

# If no GPU nodes, check EC2 capacity and Karpenter logs
```

---

## Cost Monitoring

### 1. Terraform Cost Estimation (Before Deploying)

```bash
# Install Infracost (optional)
curl https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | bash

# Estimate costs
infracost breakdown --path terraform/
```

### 2. Real-Time Cost Tracking (After Deploying)

```bash
# Install Kubecost
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm upgrade --install kubecost kubecost/cost-analyzer \
  --namespace kubecost --create-namespace

# Port-forward
kubectl port-forward -n kubecost svc/kubecost 9090:9090 &

# Visit http://localhost:9090
```

### 3. AWS Cost Explorer

Use AWS console:
- Cost Explorer → EC2 instances (filter by tags: `ManagedBy=karpenter`)
- See actual GPU instance costs
- Compare spot vs. on-demand savings

---

## Cleanup

### Remove All Resources

```bash
# 1. Delete Argo CD applications
argocd app delete root -n argocd --cascade

# 2. Delete Argo CD itself
kubectl delete namespace argocd

# 3. Destroy Terraform infrastructure
cd terraform
terraform destroy -var-file="environments/dev.tfvars"
```

---

## Next Steps

1. **Customize inference workload**: Replace `apps/inference/deployment.yaml` with your actual model
2. **Add monitoring alerts**: Configure AlertManager rules in `environments/*/values/prometheus-values.yaml`
3. **Enable spot interruption**: Add SQS queue for graceful drains
4. **Implement secrets management**: Use Sealed Secrets or External Secrets Operator
5. **Set up CI/CD**: Add GitHub Actions or GitLab CI for automated testing
6. **Production hardening**: Review security best practices in production environment values

---

## Support

- **Blog post**: [Zero to GPU: Auto-Scaling Inference on EKS](https://your-blog)
- **GitHub Issues**: [karpenter-keda-gpu-inference-demo/issues](https://github.com/YOUR_ORG/karpenter-keda-gpu-inference-demo/issues)
- **Community**: [Karpenter Slack](https://karpentercommunity.slack.com)

