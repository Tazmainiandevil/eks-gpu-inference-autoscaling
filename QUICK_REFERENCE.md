# Quick Reference: Common Operations

Fast lookups for day-to-day tasks on the GPU inference cluster.

---

## 🚀 One-Time Setup

```bash
# 1. Clone repo
git clone https://github.com/YOUR_ORG/karpenter-keda-gpu-inference-demo
cd karpenter-keda-gpu-inference-demo

# 2. Deploy infrastructure (15-20 min)
cd terraform && terraform init && terraform apply -var-file="environments/dev.tfvars"

# 3. Get cluster credentials
export CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --name $CLUSTER_NAME

# 4. Install Argo CD (5 min)
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 5. Deploy stack via GitOps (10 min)
kubectl apply -f argocd/app-of-apps.yaml

# Watch deployment
kubectl get app -n argocd -w
```

---

## 📊 Check Cluster Health

```bash
# System components
kubectl get nodes                    # Managed nodes
kubectl get nodepools -n karpenter   # Karpenter pools (general + gpu)
kubectl get pods -n karpenter        # Karpenter controller
kubectl get pods -n keda             # KEDA operator

# GPU resources
kubectl get nodes -L nvidia.com/gpu  # GPU node assignments
kubectl top nodes                    # CPU/memory usage

# Workload
kubectl get pods                     # All pods
kubectl describe pod -l app=inference-pod
```

---

## 🎯 Monitor Autoscaling

### KEDA Triggers

```bash
# View ScaledObject status
kubectl describe scaledobject inference-scaler

# Check current replica count
kubectl get deployment inference-pod -o wide

# Watch scaling in real-time
watch kubectl get pods -l app=inference-pod

# KEDA metrics
kubectl port-forward -n keda svc/keda-operator 8080:8080
curl http://localhost:8080/metrics | grep keda_scaler_active
```

### Karpenter Node Management

```bash
# Watch nodes launching
watch kubectl get nodes -L karpenter.sh/capacity-type

# Karpenter logs (last 100 lines)
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100

# Consolidation activity
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep consolidate

# NodePools are cluster-scoped resources (no -n flag)
kubectl get nodepool
kubectl get nodepool gpu -o yaml | grep -A5 disruption
```

---

## 🧪 Load Testing & Validation

```bash
# Port-forward Pushgateway first (required for all scripts)
kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring

# End-to-end architectural validation (~15 min)
./scripts/validate-scaling.sh

# Load test modes
./scripts/load-test.sh pulse    # ramp → hold 5 min → drain (full lifecycle demo)
./scripts/load-test.sh ramp     # gradually increase queue depth
./scripts/load-test.sh hold     # sustain at MAX_DEPTH (default 20)
./scripts/load-test.sh drain    # set depth to 0 (trigger scale-down)
./scripts/load-test.sh status   # print current queue depth metric

# Override defaults
QUEUE_DEPTH=30 HOLD_SECONDS=600 ./scripts/load-test.sh pulse
```

---

## ⚡ Knative Scale-to-Zero (HTTP)

Knative Serving is deployed alongside KEDA as an alternative for HTTP-native workloads.

```bash
# Check KService status
kubectl get ksvc -n inference

# Check Knative pods (activator buffers requests during cold start)
kubectl get pods -n knative-serving

# Send a request (cold start triggers pod + node provisioning)
kubectl port-forward svc/knative-local-gateway 8080:80 -n istio-system
curl -H "Host: inference.inference.svc.cluster.local" http://localhost:8080/infer

# Watch scale events
kubectl get pods -n inference -w

# Check autoscaling config
kubectl get kpa -n inference
```

KEDA vs Knative comparison:
- **KEDA**: Queue-depth / batch workloads — scales on Prometheus metrics
- **Knative**: Interactive HTTP — scales on concurrency (KPA), instant activator buffering

---

## 📈 Access Dashboards

```bash
# Prometheus (metrics database)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090
# Query: up{job=~"karpenter|keda"}

# Grafana (visualizations)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# → http://localhost:3000 (admin / admin)

# Argo CD (GitOps status)
kubectl port-forward -n argocd svc/argocd-server 8080:443
# → https://localhost:8080
```

---

## 🔄 Update Configurations

### Change Replica Limits

```bash
# Edit ScaledObject (min/max replicas)
kubectl edit scaledobject inference-scaler

# Example:
# spec:
#   minReplicaCount: 0      # Scale to zero
#   maxReplicaCount: 50     # Max parallelism
```

### Modify Prometheus Trigger Threshold

```bash
# Edit ScaledObject
kubectl edit scaledobject inference-scaler

# Example: Change from 5 jobs to 10 jobs
# triggers:
# - metadata:
#     query: ALERTS{alertname="HighGPUQueueDepth"}
#     threshold: "10"
```

### Change Node Consolidation Window

```bash
# Edit NodePool (consolidation schedule)
kubectl edit nodepool gpu -n karpenter

# Example: 5 minute consolidation window (production)
# spec:
#   consolidationPolicy:
#     nodes: "10%"
#     expireAfter: 5m
#     expireSeconds: 300
```

### Scale Infrastructure (Karpenter Replicas)

```bash
# For HA (production), edit values:
# environments/production/values/karpenter-values.yaml
# → increase replicas: 2

# Trigger Argo sync
argocd app sync karpenter-helm -n argocd
```

---

## 🐛 Debugging

### Inference Pod Failed to Start

```bash
# Get pod details
kubectl describe pod <pod-name>

# Check logs
kubectl logs <pod-name>

# Common issues:
# 1. GPU affinity not matching → Add taint tolerations
# 2. Image pull failed → Check ECR credentials
# 3. Resource limit exceeded → Check GPU availability

# Verify GPU node is available
kubectl get nodes -L nvidia.com/gpu
```

### KEDA Not Scaling

```bash
# Check trigger status
kubectl describe scaledobject inference-scaler

# Test Prometheus query manually
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090
# Query (from ScaledObject spec): ALERTS{alertname="..."}

# Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator | grep inference
```

### Karpenter Not Provisioning GPU Nodes

```bash
# Check if GPU pool exists (cluster-scoped)
kubectl get nodepool gpu

# Test IAM permissions
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
KARPENTER_ROLE="eks-gpu-cluster-karpenter-role"

aws iam get-role-policy --role-name $KARPENTER_ROLE --policy-name karpenter-policy

# Check if GPU quota sufficient
aws service-quotas list-service-quotas --service-code ec2 | grep g4dn

# Check Karpenter logs for capacity issues
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep "capacity\|insufficient"
```

### Pod Eviction Issues

```bash
# Check Pod Disruption Budget
kubectl get pdb
kubectl describe pdb inference-pod-pdb

# If pods keep getting evicted, increase minAvailable
kubectl edit pdb inference-pod-pdb
# → minAvailable: 1   (keeps at least 1 pod running)
```

---

## 📝 Common Git Operations

### Update ArgoCD Sync

```bash
# Manual sync (useful for testing)
argocd app sync root

# Sync with pruning (removes Argo-deleted resources from cluster)
argocd app sync root --prune

# Force re-sync of one application
argocd app sync inference-pod
```

### Commit Configuration Changes

```bash
# Make edits to values files
# ...

# Stage changes
git add environments/dev/values/

# Commit
git commit -m "Increase KEDA max replicas from 30 to 50"

# Push to trigger Argo re-sync
git push origin main

# Monitor sync
kubectl get app -n argocd -w
```

### Rollback to Previous Version

```bash
# View commit history
git log --oneline

# Revert to specific commit
git revert abc1234

# Or reset (destructive)
git reset --hard abc1234

# Argo will auto-sync your changes
```

---

## 💰 Cost Management

### Check Spending (AWS Console)

```bash
# Cost Explorer
aws ce get-cost-and-usage --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY --metrics BlendedCost --group-by Type=DIMENSION,Key=SERVICE
```

### Check Cluster Spending (OpenCost)

```bash
# Port-forward OpenCost (already deployed via ArgoCD)
kubectl port-forward svc/opencost 9003:9003 -n opencost

# Cost breakdown by app label (last 1 day)
curl 'http://localhost:9003/allocation?window=1d&aggregate=label:app' | python3 -m json.tool
```

### Reduce Costs

```bash
# Increase spot utilization (reduce on-demand)
# Edit: environments/dev/values/karpenter-values.yaml
# karpenterController:
#   resources:
#     limits:
#       memory: 1Gi    # Reduce if possible

# Extend consolidation window (consolidate less frequently)
# NodePool spec: expireAfter: 10m

# Use Compute Savings Plans (AWS console)
# Example: 1-year for 30% discount on GPU instances
```

---

## 🔐 Security Checks

### Verify EKS Pod Identity (IAM for pods)

This cluster uses **EKS Pod Identity** (not IRSA). Roles are bound to service accounts via PodIdentityAssociation objects, managed by Terraform.

```bash
# List Pod Identity associations on the cluster
aws eks list-pod-identity-associations \
  --cluster-name eks-gpu-demo \
  --region eu-west-2

# Check the Karpenter association
aws eks describe-pod-identity-association \
  --cluster-name eks-gpu-demo \
  --region eu-west-2 \
  --association-id <id-from-list>

# Verify the bound IAM role
aws iam get-role --role-name eks-gpu-cluster-karpenter-role
```

### Check Pod Security Standards

```bash
# Verify PSP or PSS labels
kubectl get namespace default -o yaml | grep pod-security

# Check if pods run as root
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[*].securityContext.runAsUser}\n'
```

### Audit Cluster Access

```bash
# Who accessed Karpenter recently?
aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=karpenter

# Recent API calls
kubectl logs -n karpenter --tail=50 | grep "create\|delete"
```

---

## 📞 Getting Help

| Issue | Command | Resource |
|-------|---------|----------|
| Karpenter docs | `helm show readme stable/karpenter` | https://karpenter.sh/docs |
| KEDA docs | `kubectl api-resources \| grep scaledobject` | https://keda.sh/docs |
| EKS docs | `aws eks describe-cluster --name $CLUSTER_NAME` | https://docs.aws.amazon.com/eks |
| Argo CD docs | `argocd version` | https://argoproj.github.io/argo-cd |

---

## ✨ Tips & Tricks

```bash
# Alias for common commands
alias kn='kubectl config set-context --current --namespace'
alias kgp='kubectl get pods'
alias kgn='kubectl get nodes'
alias kdesc='kubectl describe'

# Watch Argo app status
watch 'argocd app get root | grep -E "Name:|Status:|Sync|Health"'

# Monitor cost in real-time
watch 'kubectl top nodes; echo "---"; kubectl get pods --all-namespaces | wc -l'

# Quick health check
kubectl get nodes && kubectl get pods -A | grep -v Running && echo "✅ All systems nominal"
```

---

**Last Updated**: May 2026
**Version**: 2.0
