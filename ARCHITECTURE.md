# Three-Tier Node Architecture

This document explains the design decision to use **three separate node groups** (system, app, GPU) instead of merging them.

---

## 🎯 Architecture Principles

The three-tier design follows Kubernetes best practices:

1. **Separation of Concerns** — Each tier has distinct workload characteristics and scaling needs
2. **Cost Accountability** — Clear billing per tier (system overhead, app baseline, GPU inference)
3. **Operational Safety** — System pod availability independent from app/GPU volatility
4. **Scaling Flexibility** — Each tier can scale independently

---

## 📊 Node Group Breakdown

### Tier 1: System Nodes (Always-On, Managed Group)

**Purpose**: Core Kubernetes infrastructure and platform services

**Taint**: `system=true:NoSchedule`

**Pods (tolerate system taint)**:
- `karpenter/karpenter` — Node autoprovisioning engine
- `keda/keda-operator` — Pod autoscaling operator
- `monitoring/prometheus` — Metrics database
- `monitoring/grafana` — Dashboards
- `kyverno/kyverno` — Policy engine
- `kubelet` (system), `kube-proxy` (system), `coredns` (system)

**Sizing by Environment**:

| Environment | Desired | Min | Max | Instance Type | Capacity |
|---|---|---|---|---|---|
| **dev** | 1 | 1 | 3 | t3.medium | ON_DEMAND |
| **staging** | 2 | 2 | 4 | t3.medium/large | ON_DEMAND |
| **production** | 3 | 3 | 5 | m6i.large | ON_DEMAND |

**Why "always-on"?**
- Karpenter runs on system nodes; if Karpenter evicted, no nodes can be provisioned (deadlock)
- Prometheus/monitoring must be stable for observability
- Policy engine must enforce constraints predictably

**Cost**: ~$20-30/month (dev), ~$50-100/month (prod)

---

### Tier 2: App Nodes (Flexible, Managed Group)

**Purpose**: General-purpose application workloads

**Taints**: None (default scheduling)

**Pods (no toleration needed)**:
- User APIs and microservices
- Message queue workers
- Data pipelines
- Model registry services
- Any non-GPU, non-system workloads

**Sizing by Environment**:

| Environment | Desired | Min | Max | Instance Type | Capacity |
|---|---|---|---|---|---|
| **dev** | 1 | 1 | 3 | t3.small/medium | ON_DEMAND |
| **staging** | 1 | 1 | 5 | t3.medium/large | SPOT |
| **production** | 2 | 2 | 10 | m6i.large | ON_DEMAND |

**Why separate from system?**
- Scales independently (app scale doesn't compete with system stability)
- Can use SPOT instances in dev/staging (cost savings)
- Isolates non-GPU work from GPU resource conflicts

**Cost**: ~$10-20/month (dev), ~$50-150/month (prod)

---

### Tier 3: GPU Nodes (Baseline + Dynamic, Managed Group + Karpenter)

**Purpose**: GPU-intensive inference workloads

**Taint**: `gpu=true:NoSchedule`

**Pods (require gpu toleration)**:
- Inference deployments (replicas scaled by KEDA)
- Model serving workloads
- GPU-based batch processing

**Sizing by Environment**:

| Environment | Baseline | Min | Max | Instance Type | Capacity |
|---|---|---|---|---|---|
| **dev** | 0 | 0 | 2 | g4dn.xlarge | SPOT |
| **staging** | 1 | 1 | 3 | g4dn.xlarge | ON_DEMAND |
| **production** | 2 | 2 | 20 | p4d.24xlarge | ON_DEMAND |

**How Scaling Works**:
- **Baseline nodes** (managed group, Terraform): Always-on minimum capacity
- **Dynamic nodes** (Karpenter): Adds nodes when KEDA scales pods beyond baseline

Example (dev):
```
KEDA target: 5 pods
Available baseline: 0 GPU nodes
→ Karpenter launches 1 new g4dn.xlarge (spot) node
→ 5 pods schedule on new node
→ Idle 3m → Karpenter consolidates → Node terminated
```

Example (prod):
```
KEDA target: 10 pods
Available baseline: 2 p4d.24xlarge nodes (fit ~20 pods)
→ All 10 pods schedule on baseline nodes
→ No Karpenter action needed
→ Pods stay warm on expensive p4d ($55/hr cost allocated to inference revenue)
```

**Scaling approaches** (both are demonstrated in this repo):

| Approach | Driver | Best for |
|---|---|---|
| **KEDA + Prometheus** | `gpu_job_queue_depth` gauge | Batch / queue-depth workloads |
| **Knative KPA** | HTTP concurrency | Interactive / request-latency workloads |

KEDA scales based on a queue metric pushed to Prometheus. Knative scales on live request concurrency via the KPA, with the Knative activator buffering requests during cold start so no request is dropped.

**Why separate from app nodes?**
- GPU nodes cost $3-10/hour vs. $0.10/hour for t3 nodes
- Isolates noisy inference workloads from critical services
- Allows different consolidation strategies (GPU: aggressive; app: conservative)

**Cost**: ~$0-10/month (dev, scales down), ~$400-800/month (prod, 2×p4d baseline)

---

## 💰 Cost Breakdown Example (Production)

```
System tier:   3 nodes × m6i.large (on-demand)      = ~$90/mo
App tier:      2 nodes × m6i.large (on-demand)      = ~$60/mo
GPU tier:      2 nodes × p4d.24xlarge (always-on)   = ~$3,300/mo
               + spot burst capacity (if needed)     = +$0-600/mo
               ──────────────────────────────────────
Total baseline:                                       ~$3,450/mo
Per-inference-request cost (w/ OpenCost):            ~$0.001-0.01/pod
```

Compare to naive **single node group** (all mixed):
- Can't isolate GPU cost (Prometheus using same tier as inference)
- Can't guarantee system pod SLOs
- Harder to reason about scaling behavior

---

## 🔄 Scaling Behaviors

### Scenario 1: Morning Traffic Spike (Production)

```
08:00 → Traffic arrives (100 requests/sec)
  │
  ├─ KEDA prometheus trigger fires
  ├─ Target: 20 inference pods
  ├─ Baseline GPU: 2 nodes, fit 20 pods
  └─ Result: Pods schedule immediately on baseline (NO NEW NODES)
     Cost impact: $0 (pods use already-paid baseline)

10:00 → Spike passes
  │
  ├─ KEDA scales down to 2 pods
  ├─ GPU nodes idle
  ├─ System nodes still running (always-on)
  ├─ App nodes may scale down (if services also idle)
  └─ Result: Low-cost idle state
```

### Scenario 2: Unexpected Burst (Production)

```
13:00 → Unexpected 300 RPS spike
  │
  ├─ KEDA scales to max 30 pods
  ├─ Baseline 2 nodes fit ~20 pods
  ├─ Remaining 10 pods pending
  │
  ├─ Karpenter detects pending pods
  ├─ Launches 1 additional p4d.24xlarge
  ├─ 10 pods schedule on new node
  └─ Result: Burst handled. Cost: +$55/hr until consolidation
     Consolidation window: 4h (prod setting)

17:00 → Traffic normalize
  │
  ├─ KEDA scales back to 2 pods
  ├─ 3 GPU nodes now idle
  ├─ Karpenter waits 4h consolidation window
  ├─ 21:00 → Consolidates, removes extra node
  └─ Result: Back to 2 baseline nodes
```

### Scenario 3: App Workload Scaling (Independent)

```
App nodes SCALE UP:          GPU nodes STAY SAME:
  │
  ├─ Heavy batch ETL job launches
  ├─ App tier targets 5 pods
  ├─ Current: 2 app nodes
  ├─ Karpenter (via Terraform scale_config)
  │  adds nodes until fit
  └─ GPU inference unaffected (separate tier)
```

---

## 🔐 Operational Safety

### Benefit: System Pod Availability

**Old design** (single managed group):
```
Scenario: App pod surge
  App tier wants 50 pods
  → Managed group fills up
  → Karpenter waiting to schedule (but Karpenter itself pending!)
  → Deadlock: k no nodes available

Result: No new nodes can be provisioned
        Inference pods stuck pending
        Karpenter starved
```

**New design** (three tiers):
```
Scenario: App pod surge
  App tier wants 50 pods
  → Managed group fills up
  → System nodes ISOLATED (tainted, system=true)
  → Karpenter still running on system nodes
  → Karpenter provisions GPU nodes for inference
  → GPU workloads healthy
  → App can wait or trigger upstream backpressure

Result: System health maintained
        Inference continues
        App scales gracefully
```

---

## 📏 Scaling Strategy Per Environment

### Development

```yaml
system_node_group:
  desired: 1
  min: 1
  max: 3
  
app_node_group:
  desired: 1
  min: 1
  max: 3
  
gpu_node_group:
  baseline: 0          # Scale from zero
  max: 2               # Small burst capacity

Cost: ~$150/month if always running
      ~$50-100/month if stopped outside hours
```

**Use case**: Local testing, experimentation, cost consciousness

### Staging

```yaml
system_node_group:
  desired: 2
  min: 2
  max: 4
  
app_node_group:
  desired: 1
  min: 1
  max: 5
  
gpu_node_group:
  baseline: 1          # Warm node for latency testing
  max: 3

Cost: ~$400-600/month
```

**Use case**: Load testing, validation, near-prod behavior

### Production

```yaml
system_node_group:
  desired: 3           # HA across AZs
  min: 3
  max: 5
  
app_node_group:
  desired: 2           # Baseline for services
  min: 2
  max: 10
  
gpu_node_group:
  baseline: 2          # HA: 2 nodes across AZs
  max: 20              # Burst to 20× models

Cost: ~$3,500/month baseline + burst ($500-1000/mo additional)
```

**Use case**: Production inference, SLA guarantees, cost visibility

---

## 🔧 Configuration (Terraform)

Each tier is independently configurable:

```hcl
# system_node_group (tier 1)
variable "system_node_group" {
  type = object({
    desired_capacity = number
    min_capacity     = number
    max_capacity     = number
    instance_types   = list(string)
    capacity_type    = string
  })
}

# app_node_group (tier 2)
variable "app_node_group" {
  type = object({
    desired_capacity = number
    min_capacity     = number
    max_capacity     = number
    instance_types   = list(string)
    capacity_type    = string
  })
}

# gpu_node_group (tier 3)
variable "gpu_node_group" {
  type = object({
    instance_type  = string
    desired_size   = number
    min_size       = number
    max_size       = number
    spot           = bool
  })
}
```

Per environment:
```hcl
# dev.tfvars
system_node_group = { desired_capacity = 1, ... }
app_node_group    = { desired_capacity = 1, ... }

# production.tfvars
system_node_group = { desired_capacity = 3, ... }
app_node_group    = { desired_capacity = 2, ... }
```

---

## 🎓 Decision Matrix

| Question | Old (Single Group) | New (Three Tiers) |
|----------|---|---|
| Can system pods be evicted? | ❌ Deadlock risk | ✅ Protected by taint |
| Can I scale app without GPU? | ❌ Competes for resources | ✅ Independent tier |
| Clear cost per workload? | ❌ Mixed billing | ✅ Per-tier cost tracking |
| Easier to understand? | ✅ Simpler logic | ✅ Clear separation |
| Operational complexity | ⚠️ Hidden interactions | ✅ Transparent boundaries |

---

## 📚 Further Reading

- **Kubernetes Node Pools Best Practices**: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- **Karpenter Consolidation**: https://karpenter.sh/docs/concepts/disruption/
- **Pod Disruption Budgets**: https://kubernetes.io/docs/tasks/run-application/configure-pdb/

---

**Summary**: Three tiers provide **operational safety**, **cost accountability**, and **clear scaling semantics** — essential for production GPU inference at scale.
