# Karpenter + KEDA GPU Inference Autoscaling on EKS

Production-ready reference implementation for cost-optimized GPU inference workloads on AWS EKS. Combines Karpenter for intelligent node provisioning, KEDA for demand-driven pod scaling, and Knative for HTTP-based scale-to-zero. Complete Infrastructure-as-Code (Terraform) and GitOps (ArgoCD) included.

**Companion blog post**: [Production‑Ready GPU Inference Autoscaling on EKS with Karpenter, KEDA, and Dragonfly](https://codingwithtaz.blog/2026/05/13/production-ready-gpu-inference-autoscaling-on-eks-with-karpenter-keda-and-dragonfly/)

---

## Architecture

```
VPC (10.0.0.0/16)
  ├── Public subnets   — NAT Gateway, Internet Gateway
  └── Private subnets  — EKS nodes, VPC endpoints for ECR/S3

EKS Cluster (Kubernetes 1.35)
  ├── Managed node group  — always-on system nodes (t3.medium; Karpenter, KEDA, monitoring)
  ├── GPU node group      — baseline ON_DEMAND GPU nodes (0 dev, 4 production)
  └── Karpenter NodePools — burst capacity on spot, scale to zero when empty
        ├── general  — t3.medium/large spot for CPU overflow
        └── gpu      — g4dn/g5 spot (g4dn.xlarge, g4dn.2xlarge, g5.xlarge, g5.2xlarge; on-demand fallback)

Platform (deployed via ArgoCD wave 0)
  ├── Karpenter v1.9.0               — node autoprovisioner
  ├── KEDA v2.19.0                   — pod autoscaler (Prometheus, Kafka, cron triggers)
  ├── NVIDIA device plugin v0.19.1   — exposes nvidia.com/gpu + GPU Feature Discovery
  ├── Knative Serving v1.21.1        — HTTP serving with scale-to-zero
  ├── Kourier v1.21.0               — lightweight Knative ingress (net-kourier)
  ├── kube-prometheus-stack v82.10.4 — metrics, Grafana, alerting
  ├── Prometheus Pushgateway         — metric ingestion for load tests and batch jobs
  ├── Kyverno                        — policy enforcement (GPU requests, tolerations, PDBs)
  ├── OpenCost                       — GPU cost visibility per namespace/workload
  └── Dragonfly v1.6.15              — P2P image distribution (production)

Inference workload (deployed via ArgoCD wave 1)
  └── Deployment + ScaledObject + PDB
```

### Scaling lifecycle

```
Job arrives → gpu_job_queue_depth Gauge increments
           → KEDA polls Prometheus every 15s
           → replicas 0 → N
           → pod Pending (no GPU node)
           → Karpenter provisions g4dn/g5 spot node (~37s cold; ~3s Dragonfly-warm)
           → AL2023 AMI boots (NVIDIA drivers pre-installed)
           → device plugin advertises nvidia.com/gpu
           → pod scheduled → Dragonfly distributes image P2P
           → inference Running

Queue drains → KEDA cooldown 300s → replicas → 0
            → Karpenter WhenEmpty consolidation (3m dev / 2h prod)
            → node terminated
```

#### Cold start reality

The first request after a scale-to-zero event waits through every phase below. This is not a bug — it is the cost of paying only when you run.

| Phase | Stub container (cold) | Stub container (Dragonfly-warm) | Real model (e.g. 7B) | Notes |
|---|---|---|---|---|
| Node boot (Karpenter + AL2023 AMI) | ~37s | ~3s | ~37s | Karpenter EC2 Fleet; warm EC2 capacity can be near-instant |
| Image pull | ~47s | ~4s | 3–8 min | Dragonfly serves from cluster P2P cache after first pull |
| Model load into GPU VRAM | none | none | 2–5 min | Depends on model size and storage throughput |
| **Total first-request latency** | **~84s** | **~7s** | **~8–18 min** | Measured on g4dn.xlarge, eu-west-2, May 2026 |

Mitigation strategies (in order of effectiveness):
- **Knative `minScale: 1`** — keeps one warm replica; eliminates cold start entirely for interactive workloads
- **Dragonfly P2P** — reduces image pull from ECR registry to ~10–30 s on nodes that already pulled it once
- **Production managed GPU node baseline** — always-on node for SLA-sensitive paths; Karpenter handles burst

---

## Repository structure

```
eks-gpu-inference-autoscaling/
├── argocd/
│   ├── app-of-apps.yaml                       # Root Application — apply this first
│   ├── applicationset-platform-helm.yaml      # Karpenter, KEDA, Prometheus, Pushgateway, etc.
│   ├── applicationset-platform-kustomize.yaml # Knative Serving, Prometheus rules/dashboards
│   ├── applicationset-apps.yaml               # Inference workload
│   └── applicationset-security.yaml           # Namespaces, quotas, network policies, PDBs
├── apps/
│   ├── inference/
│   │   ├── deployment.yaml                    # GPU Deployment + Service + PDB
│   │   ├── scaledobject.yaml                  # KEDA ScaledObject (Prometheus + cron triggers)
│   │   ├── servicemonitor.yaml                # Prometheus ServiceMonitor for /metrics scraping
│   │   ├── kustomization.yaml
│   │   └── stub/
│   │       ├── Dockerfile                     # Lightweight validation container (no CUDA needed)
│   │       └── server.py                      # HTTP stub: /health /ready /metrics /queue/depth /infer
│   └── knative-inference/
│       ├── kservice.yaml                      # Knative KService — HTTP scale-to-zero alternative
│       └── kustomization.yaml
├── environments/
│   ├── dev/
│   │   ├── inference/kustomization.yaml       # CPU sim: removes GPU affinity/requests, deletes PDB
│   │   ├── knative-inference/kustomization.yaml
│   │   └── values/                            # Dev overrides (spot, 3m consolidation, g4dn)
│   ├── staging/
│   │   ├── inference/kustomization.yaml       # maxReplicaCount: 20
│   │   ├── knative-inference/kustomization.yaml
│   │   └── values/                            # Staging overrides
│   └── production/
│       ├── inference/kustomization.yaml       # minReplicaCount: 2, maxReplicaCount: 30 (HA)
│       ├── knative-inference/kustomization.yaml
│       └── values/                            # Production overrides (on-demand, 2h consolidation)
├── k8s/
│   ├── 00-namespaces.yaml                     # PSS labels per namespace
│   ├── 01-resourcequotas.yaml
│   ├── 02-poddisruptionbudget.yaml
│   ├── 03-network-policies.yaml               # Default-deny + inference egress rules
│   ├── 04-priorityclasses.yaml
│   ├── 05-storageclass.yaml                   # gp2 StorageClass (default)
│   ├── 06-vpa.yaml                            # VPA for inference pod (Auto mode)
│   └── 08-limitranges.yaml                    # Default cpu/memory limits for inference namespace (required for Knative queue-proxy sidecar)
├── platform/
│   ├── karpenter/
│   │   ├── nodepool.yaml                      # General + GPU NodePools (g4dn/g5, spot+on-demand)
│   │   └── values.yaml
│   ├── keda/values.yaml
│   ├── nvidia-device-plugin/
│   │   └── values.yaml                        # Device plugin (version from chart appVersion) + GFD enabled
│   ├── prometheus/
│   │   ├── values.yaml
│   │   ├── rules/
│   │   │   └── gpu-scaling-alerts.yaml        # PrometheusRule — 8 alerts
│   │   └── dashboards/
│   │       └── gpu-scaling-dashboard.yaml     # Grafana: queue depth, replicas, nodes, costs
│   ├── pushgateway/values.yaml                # Receives gpu_job_queue_depth from load tests
│   ├── knative-serving/
│   │   ├── kustomization.yaml
│   │   ├── config-deployment.yaml             # Skips ECR digest resolution (kubelet pulls via node IAM role)
│   │   └── config-network.yaml               # Sets Kourier as the Knative ingress class
│   ├── kourier/kustomization.yaml             # Knative network layer (NodePort in demo; see production checklist)
│   ├── kyverno/policies/                      # require-gpu-request/toleration/pdb
│   ├── opencost/values.yaml                   # GPU cost per workload (configure spotDataBucket)
│   └── dragonfly/values.yaml                  # P2P image distribution
├── scripts/
│   ├── setup.sh                               # One-shot bootstrap: patches placeholders, builds + pushes stub image
│   ├── teardown.sh                            # Scales to zero, verifies cost, optionally destroys cluster
│   ├── load-test.sh                           # Drives KEDA scaling via Pushgateway
│   └── validate-scaling.sh                    # End-to-end validation — writes scaling-results-*.json
└── terraform/
    ├── main.tf                                # VPC, EKS, IAM, node groups, SQS spot queue
    ├── variables.tf
    ├── outputs.tf
    ├── versions.tf
    ├── backend.tf                             # S3 backend stub (configure via backend.hcl)
    ├── backend.hcl.example                    # Copy to backend.hcl and fill in your bucket details
    └── budgets.tf                             # AWS Budget alerts (daily + monthly spend limits)
```

---

## Quick start

### Prerequisites

- AWS account with GPU instance quota (g4dn.xlarge minimum)
- `terraform` >= 1.9.0
- `kubectl` >= 1.29
- `aws-cli` v2 configured with credentials
- `helm` >= 3.12
- `docker`
- `git`
- `curl` (for load test scripts)

### Step 1: Run setup.sh

`setup.sh` handles all one-off configuration in a single command: it detects your AWS account and GitHub org, replaces all placeholder values across the repo, creates the ECR repository, builds and pushes the inference stub image, and prints exact next steps.

```bash
git clone https://github.com/YOUR_ORG/eks-gpu-inference-autoscaling.git
cd eks-gpu-inference-autoscaling

./scripts/setup.sh --env dev
```

What it does:
- Replaces `YOUR_ORG` and `YOUR_ENV` in all ArgoCD manifests
- Replaces `ECR_REGISTRY_PLACEHOLDER` in `platform/dragonfly/values.yaml` and `platform/dragonfly/containerd-config/containerd-config-daemonset.yaml` with your actual ECR registry URL
- Replaces `YOUR_AWS_ACCOUNT_ID` / `YOUR_AWS_REGION` in environment image overlays
- Replaces `CLUSTER_ID_PLACEHOLDER` in `platform/opencost/values.yaml` with the cluster name from `dev.tfvars`
- Creates the `inference-stub` ECR repository if it doesn't exist
- Builds `apps/inference/stub/` and pushes `<account>.dkr.ecr.<region>.amazonaws.com/inference-stub:latest`

Then commit the patched files before proceeding:

```bash
git add -p && git commit -m "chore: apply setup.sh configuration"
git push
```

### Step 2: Infrastructure (Terraform)

Before applying, set your budget alert email. Create `terraform/environments/dev.local.tfvars` (gitignored) with:
```hcl
budget_alert_email = "you@example.com"
```

```bash
cd terraform

# Local state (default — fine for dev/testing)
terraform init

# Optional: migrate to remote state later (see backend.hcl.example)
# cp backend.hcl.example backend.hcl && terraform init -backend-config=backend.hcl -migrate-state

terraform apply -var-file="environments/dev.tfvars" -var-file="environments/dev.local.tfvars"

cd ..
```

Provisions: VPC (NAT Gateway, public + private subnets, route tables), EKS 1.35, IAM roles (Karpenter + EBS CSI via EKS Pod Identity, node role), managed node groups (system + app + GPU), EC2 Spot service-linked role, SQS spot interruption queue, VPC endpoints (ECR API, ECR DKR, S3, STS), `eks-pod-identity-agent` addon, and AWS Budget alerts (see `terraform/budgets.tf`).

> **Cost guard rail**: Terraform creates a daily budget alert at $20 USD (80% actual + 100% forecast) sent to `budget_alert_email` in your tfvars. Set this before applying.

### Step 3: Configure kubeconfig

```bash
# cluster_name and region come from your terraform/environments/dev.tfvars
aws eks update-kubeconfig \
  --name <cluster_name> \
  --region <aws_region>
```

### Step 4: Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=available deployment \
  -n argocd --all --timeout=120s
```

### Step 5: Bootstrap the GitOps stack

```bash
# Apply the root Application — ArgoCD deploys everything from here
kubectl apply -f argocd/app-of-apps.yaml

# Watch rollout (wave 0 → wave 1)
kubectl get applications -n argocd -w
```

ArgoCD sync wave order:
- **Wave 0** — Karpenter, KEDA, Prometheus, Pushgateway, Kyverno, OpenCost, Dragonfly, NVIDIA device plugin, Knative, Prometheus rules/dashboards
- **Wave 1** — Inference Deployment + ScaledObject (after CRDs and operators are healthy)

### Step 6: Validate end-to-end

```bash
# Terminal 1 — port-forward Pushgateway
kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring

# Terminal 2 — run automated validation (~15 min)
./scripts/validate-scaling.sh
```

The script writes a timestamped `scaling-results-YYYYMMDD-HHMMSS.json` on completion with the full timeline (queue push → node ready → pods ready → scale-in elapsed seconds).

### When you're done testing

```bash
./scripts/teardown.sh           # scale to zero, verify GPU cost returns to ~$0
./scripts/teardown.sh --destroy # also runs terraform destroy (prompts for confirmation)
```

---

## Validating the architecture

```bash
# Terminal 1 — port-forward Pushgateway
kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring

# Terminal 2 — run automated validation (5 steps, ~15 min total)
./scripts/validate-scaling.sh
```

The script verifies:
1. **Prerequisites** — kubectl, Pushgateway, platform pods, device plugin, ScaledObject, NodePool
2. **Baseline** — 0 replicas, 0 Karpenter GPU nodes (scale-to-zero confirmed)
3. **Scale-out** — pushes `gpu_job_queue_depth=15`, waits for KEDA to scale (pollingInterval=30s), waits for Karpenter GPU node Ready, confirms `nvidia.com/gpu` advertised
4. **Pod readiness** — all replicas Running, `/health` probe succeeds inside pod, `nvidia-smi` checked (GPU mode — warns for stub, passes for real CUDA images)
5. **Scale-in** — clears metric, confirms KEDA scales to 0 (cooldown=300s), confirms Karpenter consolidation

On completion, a timestamped results file is written:

```
scaling-results-20260510-205558.json
{
  "validation": "FAILED",
  "pass": 24,
  "fail": 1,
  "warn": 2,
  "node_instance_type": "g4dn.xlarge",
  "elapsed_seconds": {
    "queue_to_node_ready": 3,
    "queue_to_pods_ready": 7,
    "scale_in": 285
  }
}
```

### Inference latency metrics

The stub server exposes a `POST /infer` endpoint that simulates inference work (configurable or random 50–500ms latency) and records a `inference_request_duration_seconds` histogram. Drive it during a load test to populate the Grafana p50/p95/p99 latency panels:

```bash
# From inside the cluster, or via port-forward:
kubectl port-forward svc/inference-service 8000:8000 -n inference

# Single request (returns latency_ms in response)
curl -s -X POST http://localhost:8000/infer
# {"result":"ok","latency_ms":234.7,"request_id":1}

# Sustained load — 20 concurrent requests
seq 20 | xargs -P 20 -I{} curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"latency_ms": 300}' \
  http://localhost:8000/infer > /dev/null

# Confirm histogram is populated
curl -s http://localhost:8000/metrics | grep inference_request_duration
```

### Manual load testing

```bash
./scripts/load-test.sh pulse    # ramp → hold 5 min → drain (full lifecycle)
./scripts/load-test.sh ramp     # gradually increase queue depth
./scripts/load-test.sh hold     # sustain at MAX_DEPTH (default 20)
./scripts/load-test.sh drain    # set depth to 0 (trigger scale-down)
./scripts/load-test.sh status   # print current metric value

# Override defaults
QUEUE_DEPTH=30 HOLD_SECONDS=600 ./scripts/load-test.sh pulse
```

### Using a real inference model

The stub container (`apps/inference/stub/`) proves the Karpenter + KEDA scaling mechanism without GPU quota. When you're ready to validate actual GPU inference, the easiest path is **NVIDIA Triton Inference Server with an ONNX ResNet-50** model — the image is ~8 GB and the model fits on any g4dn instance.

**1. Pull the model:**
```bash
# On a machine with internet access (or use a CI step)
docker run --rm -v "$(pwd)/models:/models" \
  nvcr.io/nvidia/tritonserver:24.01-py3 \
  sh -c "pip install -q tritonclient[http] && \
         python -c \"import torchvision, torch, onnx; \
           m = torchvision.models.resnet50(weights='IMAGENET1K_V1'); \
           torch.onnx.export(m, torch.randn(1,3,224,224), '/models/resnet50/1/model.onnx', \
             input_names=['input'], output_names=['output'])\""
```

**2. Build and push your real inference image:**
```bash
# Replace the stub Dockerfile with one based on Triton
cat > apps/inference/stub/Dockerfile <<'EOF'
FROM nvcr.io/nvidia/tritonserver:24.01-py3
COPY models/ /models/
CMD ["tritonserver", "--model-repository=/models", "--http-port=8000"]
EOF

IMAGE_TAG=$(git rev-parse --short HEAD)
docker build -t ${ECR_REGISTRY}/inference-stub:${IMAGE_TAG} apps/inference/stub/
docker push ${ECR_REGISTRY}/inference-stub:${IMAGE_TAG}
```

**3. Update the deployment image:**
```bash
# In environments/dev/inference/kustomization.yaml, set the tag:
images:
  - name: REGISTRY_PLACEHOLDER/inference-stub
    newName: ${ECR_REGISTRY}/inference-stub
    newTag: ${IMAGE_TAG}
```

**4. Validate GPU utilization in Grafana:**

The DCGM Exporter panels ("GPU Utilization %", "GPU Memory Used") will show real numbers once the Triton server begins serving requests. Expect 60–90% GPU utilization under the load test. The stub shows 0% because it performs no GPU compute.

**Alternative: vLLM for LLM inference**

For LLM workloads (Llama 3, Mistral, etc.), replace Triton with vLLM:
```bash
FROM vllm/vllm-openai:latest
# Requires p3.2xlarge (V100 16GB) or g5.xlarge (A10G 24GB) minimum for 7B models
```
Note: 7B parameter models require ~14 GB VRAM (bfloat16). g4dn.xlarge (T4, 16GB) is marginal — use g5.xlarge for headroom.

---

## Monitoring

### Grafana

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# http://localhost:3000  (admin / admin)
```

The **GPU Inference — Scaling & Cost** dashboard ships with the repo (`platform/prometheus/dashboards/`). Key panels:
- Queue depth vs replica count vs GPU node count (single time series — the core scaling proof)
- Current queue depth, active replicas, allocatable GPUs, pending pods (stat panels)
- Karpenter NodeClaim launch/terminate rate
- Pod phase distribution
- Request latency p50/p95/p99 (histogram from `/infer` endpoint)
- Throughput (req/s) and error rate
- Node provisioning state timeline
- **GPU utilization %** and **GPU memory used (GiB)** — from DCGM Exporter (only populated with real GPU workloads; requires `dcgm-exporter` running on a GPU node)
- GPU temperature (°C) and power draw (W)

### Alerts

10 PrometheusRule alerts are pre-configured (`platform/prometheus/rules/gpu-scaling-alerts.yaml`):

| Alert | Fires when |
|---|---|
| `GPUQueueDepthCritical` | Queue > 25 for 5 min |
| `GPUQueueNotDraining` | Queue > 5 with active replicas for 15 min |
| `GPUPodPendingTooLong` | Any inference pod Pending > 10 min |
| `GPUPodCrashLooping` | Container restart rate > 6/min |
| `KarpenterNotProvisioningGPUNodes` | Pods Pending, no new NodeClaims in 5 min |
| `KarpenterNodeClaimFailed` | NodeClaim terminated unexpectedly |
| `GPUNodeNotReady` | Karpenter GPU node NotReady > 5 min |
| `GPUCapacityLow` | Allocatable GPUs < 2 with queue depth > 5 for 5 min |
| `KEDAScalerError` | KEDA Prometheus scaler errors > 0 for 5 min |
| `SpotInterruptionRateHigh` | Karpenter spot interruption rate > 0.1/min for 2 min |

### Cost visibility (OpenCost)

```bash
kubectl port-forward svc/opencost 9003 -n opencost
curl 'http://localhost:9003/allocation?window=1d&aggregate=label:app'
```

OpenCost attributes costs per namespace and workload. The Grafana dashboard covers costs visible in Prometheus:

| Cost component | Source | Notes |
|---|---|---|
| EC2 nodes (managed) | `node_total_hourly_cost` | Always-on baseline |
| EC2 nodes (Karpenter GPU/general) | `node_total_hourly_cost` | Variable — tracks with load |
| EBS / PVCs | `pv_hourly_cost` | Root volumes + Prometheus/Grafana PVCs |
| Internet egress | `kubecost_network_*` | Requires network-costs DaemonSet (enabled by default) |
| Cross-zone traffic | `kubecost_network_*` | $0.01/GB each way — minimised by pinning pods to AZ |

The following costs are **not in Prometheus** and must be monitored via AWS Cost Explorer:

| Cost component | Typical rate | Note |
|---|---|---|
| NAT Gateway | $0.045/hr per AZ + $0.045/GB processed | Largest hidden cost — a single 40 GB model pull costs ~$1.80 in data processing alone. Dragonfly P2P distribution reduces repeat pulls. |
| VPC endpoints (ECR, S3) | $0.01/hr per endpoint per AZ | 3 endpoints × 2 AZs ≈ $0.06/hr fixed |
| EKS cluster fee | $0.10/hr flat | ≈ $73/month regardless of workload |
| ECR storage | $0.10/GB/month | A 40 GB model image = $4/month |

For accurate spot pricing on GPU nodes, configure `cloudProvider.aws.spotDataBucket` in `platform/opencost/values.yaml` — without it, OpenCost reports spot nodes at on-demand rates.

---

## Teardown and cost verification

After testing, always run teardown to confirm GPU nodes are gone and spend returns to near-zero.

```bash
# Scale workloads to zero, wait for Karpenter consolidation, verify cost via OpenCost
./scripts/teardown.sh

# Same, plus destroys the cluster (prompts for confirmation)
./scripts/teardown.sh --destroy
```

`teardown.sh` output includes an idle cost breakdown:

```
System node (1× t3.medium ON_DEMAND):  ~$0.05/hr
App node    (1× t3.small  ON_DEMAND):  ~$0.03/hr
EKS cluster fee:                        ~$0.10/hr
VPC endpoints (ECR, S3, STS):           ~$0.03/hr
─────────────────────────────────────────────────
Total idle:                             ~$0.21/hr (~$5/day)
```

---

## Multi-environment deployment

| Setting | Dev | Staging | Production |
|---|---|---|---|
| GPU instance | g4dn.xlarge | g5.xlarge | p4d.24xlarge |
| Baseline GPU nodes | 0 | 1 | 4 |
| Capacity type | Spot | ON_DEMAND | ON_DEMAND |
| Consolidation window | 3m | 30m | 2h |
| Dragonfly | No | Yes | Yes |
| Spot interruption queue | No | Yes | Yes |

Switch environments by applying the corresponding Terraform tfvars and pointing ArgoCD at the relevant values directory. No changes to `platform/` or `apps/` base manifests needed.

---

## Troubleshooting

### KEDA not scaling

```bash
kubectl describe scaledobject -n inference
kubectl logs -n keda -l app=keda-operator | tail -30
# Check Pushgateway has the metric:
kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring
curl http://localhost:9091/metrics | grep gpu_job_queue_depth
```

### Karpenter not provisioning

```bash
kubectl describe nodepool gpu
kubectl get nodeclaim
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -40
# IAM pre-flight check:
kubectl get ec2nodeclass default -o jsonpath='{.status.conditions}' | jq .
```

### GPU pods stay Pending

```bash
kubectl describe pod <pod> -n inference
# Common causes:
# 1. nvidia.com/gpu not advertised — device plugin not on node yet (wait 30s)
# 2. NodePool GPU limit reached — kubectl get nodepool gpu -o yaml | grep limits
# 3. Spot capacity exhausted — Karpenter falls back to on-demand automatically
```

### Node joins but stays NotReady

```bash
kubectl describe node <node>
# With terraform-aws-modules/eks v21+, EKS access entry is created automatically.
# On older versions, add the GPU node IAM role to aws-auth manually.
```

### Image pull slow on first pod

Expected — first pull from ECR takes several minutes for a 40GB+ model. Subsequent pulls on other nodes are accelerated by Dragonfly P2P. Set `consolidateAfter: 2h` on the GPU NodePool to preserve the warm cache between traffic peaks.

---

## Production checklist

**Before first deploy**
- [ ] Run `./scripts/setup.sh --env dev` — patches all placeholders and pushes stub image
- [ ] Configure S3 backend: copy `terraform/backend.hcl.example` → `terraform/backend.hcl` and fill in bucket details
- [ ] Create `terraform/environments/dev.local.tfvars` (gitignored) and set `budget_alert_email` so AWS Budget alerts reach you

**Before going to production**
- [ ] Replace stub image with your actual inference container
- [ ] Pin ArgoCD `targetRevision` to a git tag (not `main`)
- [ ] Restore Kourier `LoadBalancer` service if external Knative access is needed — either fix the EKS dual-SG tagging issue (remove the cluster tag from `eks-cluster-sg-*`) or switch to AWS Load Balancer Controller with NLB annotations. The demo uses `NodePort` to work around this. If inference is always called cluster-internally (the common pattern), `cluster-local` KService visibility + `NodePort` is correct in production too.
- [ ] Configure `cloudProvider.aws.spotDataBucket` in `platform/opencost/values.yaml` for accurate spot cost attribution (see inline instructions)
- [ ] Set Grafana `adminPassword` via Kubernetes Secret (not plaintext in values)
- [ ] Switch Kyverno policies from `audit` → `enforce` after validating with `kubectl get policyreport -A`
- [ ] Set `consolidateAfter: 2h` on GPU NodePool in production environment values
- [ ] Enable Dragonfly in staging/production environment values

**Note**: Dragonfly requires containerd configuration on EKS nodes. This is handled automatically by the `containerd-config` ArgoCD application which creates the necessary registry mirrors.

---

## Further reading

- [Karpenter docs](https://karpenter.sh/docs/) — NodePool, EC2NodeClass, disruption, v1.x migration
- [KEDA docs](https://keda.sh/docs/) — ScaledObject, Prometheus scaler, fallback
- [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin) — DaemonSet + GPU Feature Discovery
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/) — recommended for production (bundles device plugin, DCGM, MIG manager)
- [Dragonfly](https://github.com/dragonflyoss/Dragonfly2) — P2P OCI distribution
- [Karpenter DRA support](https://github.com/kubernetes-sigs/karpenter/issues/1231) — tracking issue

---

## License

MIT
