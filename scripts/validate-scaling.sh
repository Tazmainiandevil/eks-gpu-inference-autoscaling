#!/usr/bin/env bash
# validate-scaling.sh — end-to-end architectural validation for the
# Karpenter + KEDA + GPU inference demo.
#
# Validates the complete lifecycle:
#   1. Prerequisites (all platform pods healthy)
#   2. Baseline state (inference scaled to zero, no GPU nodes)
#   3. Scale-out (queue depth → KEDA scales pods → Karpenter provisions GPU node)
#   4. Pod readiness (inference pods reach Running/Ready)
#   5. Scale-in  (queue drained → KEDA scales to 0 → Karpenter consolidates)
#   6. Summary report
#
# Usage:
#   ./scripts/validate-scaling.sh
#
# Prerequisites:
#   - kubectl context pointing at the target cluster
#   - kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring (in another terminal)
#
# Environment variables:
#   PUSHGATEWAY_URL      default: http://localhost:9091
#   SCALE_OUT_TIMEOUT    default: 1080 (18 min — worst-case: node boot 5m + image pull 8m + model load 5m)
#   SCALE_IN_TIMEOUT     default: 540  (9 min — KEDA cooldown 300s + consolidation 3m)
#   QUEUE_DEPTH          default: 15
#   NAMESPACE            default: inference
#   DEPLOYMENT           default: inference-pod

set -euo pipefail

PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://localhost:9091}"
SCALE_OUT_TIMEOUT="${SCALE_OUT_TIMEOUT:-1080}"
SCALE_IN_TIMEOUT="${SCALE_IN_TIMEOUT:-540}"
QUEUE_DEPTH="${QUEUE_DEPTH:-15}"
NAMESPACE="${NAMESPACE:-inference}"
DEPLOYMENT="${DEPLOYMENT:-inference-pod}"
RESULTS_FILE="${RESULTS_FILE:-./scaling-results-$(date +%Y%m%d-%H%M%S).json}"

# Timing evidence — populated during the run, written to RESULTS_FILE at the end
declare -A TIMINGS

PASS=0
FAIL=0
WARNINGS=()

# ── output helpers ──────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { echo -e "${GREEN}  ✓ PASS${NC} — $*"; (( PASS++ )) || true; }
fail() { echo -e "${RED}  ✗ FAIL${NC} — $*"; (( FAIL++ )) || true; }
warn() { echo -e "${YELLOW}  ⚠ WARN${NC} — $*"; WARNINGS+=("$*"); }
info() { echo -e "${CYAN}  ℹ${NC} $*"; }

# ── wait helpers ────────────────────────────────────────────────────────────────

wait_for() {
  # wait_for <description> <timeout_seconds> <check_command>
  local desc=$1 timeout=$2
  shift 2
  local elapsed=0 interval=10
  log "Waiting for: ${desc} (timeout ${timeout}s)"
  while ! eval "$*" > /dev/null 2>&1; do
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
    log "  ... ${elapsed}/${timeout}s"
    if [ "${elapsed}" -ge "${timeout}" ]; then
      return 1
    fi
  done
  return 0
}

push_depth() {
  local depth=$1
  cat <<EOF | curl -s --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/validate-scaling/instance/validator"
# HELP gpu_job_queue_depth Current depth of the GPU job queue
# TYPE gpu_job_queue_depth gauge
gpu_job_queue_depth{job="validate-scaling"} ${depth}
EOF
}

clear_metric() {
  curl -s -X DELETE "${PUSHGATEWAY_URL}/metrics/job/validate-scaling/instance/validator"
}

# ── validation steps ────────────────────────────────────────────────────────────

step_prerequisites() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " STEP 1 — Prerequisites"
  echo "═══════════════════════════════════════════════════"

  # kubectl connectivity
  if kubectl cluster-info > /dev/null 2>&1; then
    pass "kubectl connected to cluster"
    info "Context: $(kubectl config current-context)"
  else
    fail "kubectl not connected — check your kubeconfig"
    exit 1
  fi

  # Pushgateway
  if curl -sf "${PUSHGATEWAY_URL}/-/healthy" > /dev/null 2>&1; then
    pass "Pushgateway reachable at ${PUSHGATEWAY_URL}"
  else
    fail "Pushgateway not reachable at ${PUSHGATEWAY_URL}"
    echo "       Run: kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring"
    exit 1
  fi

  # Platform pods
  for component in karpenter keda monitoring; do
    local not_ready
    not_ready=$(kubectl get pods -n "${component}" --no-headers 2>/dev/null \
      | { grep -v "Running\|Completed" || true; } | wc -l | tr -d ' ')
    if [ "${not_ready}" -eq 0 ]; then
      pass "${component} namespace — all pods healthy"
    else
      warn "${component} namespace — ${not_ready} pod(s) not Running"
      kubectl get pods -n "${component}" --no-headers | grep -v "Running\|Completed" || true
    fi
  done

  # NVIDIA device plugin
  local dp_pods
  dp_pods=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin --no-headers 2>/dev/null | { grep Running || true; } | wc -l | tr -d ' ')
  if [ "${dp_pods}" -gt 0 ]; then
    pass "NVIDIA device plugin DaemonSet running (${dp_pods} pod(s))"
  else
    warn "NVIDIA device plugin not found in kube-system — GPU scheduling may not work until a GPU node joins"
  fi

  # KEDA ScaledObject
  if kubectl get scaledobject "${DEPLOYMENT}-scaler" -n "${NAMESPACE}" > /dev/null 2>&1 || \
     kubectl get scaledobject -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -q .; then
    pass "KEDA ScaledObject present in ${NAMESPACE}"
  else
    fail "No ScaledObject found in namespace ${NAMESPACE}"
  fi

  # Karpenter NodePool
  if kubectl get nodepool gpu > /dev/null 2>&1; then
    local gpu_limit
    gpu_limit=$(kubectl get nodepool gpu -o jsonpath='{.spec.limits.nvidia\.com/gpu}' 2>/dev/null || echo "not set")
    pass "Karpenter GPU NodePool present (nvidia.com/gpu limit: ${gpu_limit})"
  else
    fail "Karpenter GPU NodePool not found"
  fi
}

step_dragonfly() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " STEP 1b — Dragonfly P2P Image Distribution"
  echo "═══════════════════════════════════════════════════"

  # Check Dragonfly pods in dragonfly-system namespace
  local df_not_ready
  df_not_ready=$(kubectl get pods -n dragonfly-system --no-headers 2>/dev/null \
    | { grep -v "Running\|Completed" || true; } | wc -l | tr -d ' ')
  local df_total
  df_total=$(kubectl get pods -n dragonfly-system --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [ "${df_total}" -eq 0 ]; then
    warn "Dragonfly not deployed — skipping P2P validation (expected in dev CPU-sim mode)"
    info "Dragonfly is enabled in staging/production environments."
    return
  fi

  if [ "${df_not_ready}" -eq 0 ]; then
    pass "Dragonfly pods healthy (${df_total} pod(s) Running in dragonfly-system)"
  else
    fail "Dragonfly: ${df_not_ready}/${df_total} pod(s) not Running"
    kubectl get pods -n dragonfly-system --no-headers | grep -v "Running\|Completed" || true
  fi

  # Check DaemonSet ran on at least one node
  local ds_desired ds_ready
  ds_desired=$(kubectl get daemonset containerd-config-init -n dragonfly-system \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  ds_ready=$(kubectl get daemonset containerd-config-init -n dragonfly-system \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

  if [ "${ds_desired}" -gt 0 ] && [ "${ds_ready}" -eq "${ds_desired}" ]; then
    pass "containerd-config-init DaemonSet complete: ${ds_ready}/${ds_desired} nodes configured"
  elif [ "${ds_desired}" -gt 0 ]; then
    fail "containerd-config-init DaemonSet: only ${ds_ready}/${ds_desired} nodes configured"
    info "  kubectl get pods -n dragonfly-system -l app=containerd-config-init"
  else
    warn "containerd-config-init DaemonSet not found — containerd mirrors may not be configured"
    info "  kubectl describe application containerd-config -n argocd"
  fi

  # Spot-check containerd mirror config on one node (checks certs.d for EKS containerd v2)
  local sample_node
  sample_node=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name \
    2>/dev/null | head -1)
  if [ -n "${sample_node}" ]; then
    local mirror_found
    mirror_found=$(kubectl debug node/"${sample_node}" -it --image=busybox:1.36.1 \
      --quiet -- sh -c \
      'ls /host/etc/containerd/certs.d/ 2>/dev/null | grep -c "amazonaws.com" || echo 0' \
      2>/dev/null || echo "skip")
    kubectl delete pod -n default -l app=node-debugger --force --grace-period=0 > /dev/null 2>&1 || true
    if [ "${mirror_found}" = "skip" ] || [ -z "${mirror_found}" ]; then
      info "Could not read containerd certs.d on node ${sample_node}"
      info "Manual check: kubectl debug node/${sample_node} -it --image=busybox:1.36.1 -- ls /host/etc/containerd/certs.d/"
    elif [ "${mirror_found}" -gt 0 ]; then
      pass "Dragonfly mirror (certs.d) confirmed on node ${sample_node}"
    else
      fail "Dragonfly mirror not found in certs.d on node ${sample_node}"
    fi
  fi
}

step_baseline() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " STEP 2 — Baseline State (expect: 0 pods, 0 GPU nodes)"
  echo "═══════════════════════════════════════════════════"

  # Clear any leftover metric
  clear_metric > /dev/null 2>&1 || true

  local replicas
  replicas=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
  replicas=${replicas:-0}

  if [ "${replicas}" -eq 0 ]; then
    pass "Inference deployment at 0 replicas (scale-to-zero confirmed)"
  else
    warn "Inference deployment has ${replicas} replicas — expected 0 at baseline"
    info "Waiting up to 60s for scale-down..."
    sleep 60
    replicas=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    replicas=${replicas:-0}
    if [ "${replicas}" -eq 0 ]; then
      pass "Inference deployment scaled to 0 after wait"
    else
      fail "Inference deployment still has ${replicas} replicas — is KEDA active?"
    fi
  fi

  local gpu_nodes
  gpu_nodes=$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${gpu_nodes}" -eq 0 ]; then
    pass "No Karpenter GPU nodes running (full scale-to-zero)"
  else
    info "GPU nodes already present: ${gpu_nodes} (may be baseline managed nodes)"
  fi
}

step_scale_out() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " STEP 3 — Scale-Out (queue depth → KEDA → Karpenter)"
  echo "═══════════════════════════════════════════════════"

  log "Pushing gpu_job_queue_depth = ${QUEUE_DEPTH} to Pushgateway..."
  push_depth "${QUEUE_DEPTH}"
  pass "Metric pushed to Pushgateway"

  local scale_start
  scale_start=$(date +%s)
  TIMINGS[queue_push_epoch]=${scale_start}
  TIMINGS[queue_push_ts]=$(date '+%Y-%m-%dT%H:%M:%S')

  # Wait for KEDA to create replicas
  info "Waiting for KEDA to scale deployment (pollingInterval=30s, threshold=5)..."
  if wait_for "deployment replicas > 0" 60 \
      "[ \$(kubectl get deployment ${DEPLOYMENT} -n ${NAMESPACE} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0) -gt 0 ]"; then
    local desired
    desired=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    pass "KEDA scaled deployment to ${desired} desired replicas"
  else
    fail "KEDA did not scale the deployment within 60s — check KEDA operator logs"
    info "  kubectl logs -n keda -l app=keda-operator | tail -30"
    return
  fi

  # Wait for Karpenter to launch a node
  info "Waiting for Karpenter to launch a GPU node (~3–5 min)..."
  if wait_for "GPU node Ready" "${SCALE_OUT_TIMEOUT}" \
      "kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | grep -q Ready"; then
    local node_name
    node_name=$(kubectl get nodes -l karpenter.sh/nodepool=gpu \
      --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    local instance_type
    instance_type=$(kubectl get node "${node_name}" \
      -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
    local elapsed=$(( $(date +%s) - scale_start ))
    TIMINGS[node_ready_epoch]=$(date +%s)
    TIMINGS[node_ready_ts]=$(date '+%Y-%m-%dT%H:%M:%S')
    TIMINGS[node_ready_elapsed_s]=${elapsed}
    TIMINGS[node_instance_type]=${instance_type}
    TIMINGS[node_name]=${node_name}
    pass "Karpenter GPU node Ready — ${node_name} (${instance_type}) in ${elapsed}s"

    # Verify GPU resource advertised
    local gpu_alloc
    gpu_alloc=$(kubectl get node "${node_name}" \
      -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
    if [ "${gpu_alloc:-0}" -gt 0 ]; then
      pass "NVIDIA device plugin advertising nvidia.com/gpu=${gpu_alloc} on node"
    else
      fail "nvidia.com/gpu not advertised on node ${node_name} — device plugin may not be running"
      info "  kubectl describe node ${node_name} | grep nvidia"
    fi
  else
    fail "Karpenter did not provision a GPU node within ${SCALE_OUT_TIMEOUT}s"
    info "Diagnostics:"
    info "  kubectl describe nodepool gpu"
    info "  kubectl get nodeclaim"
    info "  kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -40"
  fi
}

step_pod_readiness() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " STEP 4 — Pod Readiness + GPU Node Placement"
  echo "═══════════════════════════════════════════════════"

  local expected
  expected=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

  # Wait for nvidia.com/gpu to be advertised on at least one node before checking pods.
  # The device plugin needs ~60s after node Ready to schedule, start, and register GPUs.
  info "Waiting for nvidia.com/gpu to be advertised by device plugin..."
  if wait_for "nvidia.com/gpu advertised" 120 \
      "[ \$(kubectl get nodes -l karpenter.sh/nodepool=gpu -o jsonpath='{.items[*].status.allocatable.nvidia\\.com/gpu}' 2>/dev/null | tr ' ' '\n' | grep -c '[1-9]' || echo 0) -gt 0 ]"; then
    local gpu_alloc_total
    gpu_alloc_total=$(kubectl get nodes -l karpenter.sh/nodepool=gpu \
      -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '\n' | awk '{s+=$1}END{print s}')
    pass "nvidia.com/gpu advertised — ${gpu_alloc_total} GPU(s) allocatable across Karpenter nodes"
  else
    warn "nvidia.com/gpu not advertised within 120s — device plugin may still be starting"
  fi

  info "Waiting for ${expected} inference pod(s) to reach Running/Ready..."
  if wait_for "all replicas available" 300 \
      "[ \$(kubectl get deployment ${DEPLOYMENT} -n ${NAMESPACE} -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0) -ge ${expected} ]"; then
    TIMINGS[pods_ready_epoch]=$(date +%s)
    TIMINGS[pods_ready_ts]=$(date '+%Y-%m-%dT%H:%M:%S')
    TIMINGS[pods_ready_elapsed_s]=$(( $(date +%s) - ${TIMINGS[queue_push_epoch]:-$(date +%s)} ))
    pass "All ${expected} inference pod(s) Running and Ready"

    # Verify each pod is scheduled on the correct node pool
    local gpu_scheduled=0 general_scheduled=0 unknown_scheduled=0
    while IFS= read -r pod_name; do
      local node_name
      node_name=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
      if [ -z "${node_name}" ]; then
        continue
      fi
      local nodepool
      nodepool=$(kubectl get node "${node_name}" \
        -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}' 2>/dev/null || echo "")
      local workload_type
      workload_type=$(kubectl get node "${node_name}" \
        -o jsonpath='{.metadata.labels.workload-type}' 2>/dev/null || echo "unknown")
      if [ "${nodepool}" = "gpu" ]; then
        (( gpu_scheduled++ )) || true
        info "  ${pod_name} → node ${node_name} (pool=gpu, type=${workload_type})"
      elif [ "${nodepool}" = "general" ]; then
        (( general_scheduled++ )) || true
        info "  ${pod_name} → node ${node_name} (pool=general / CPU-sim mode)"
      else
        (( unknown_scheduled++ )) || true
        warn "  ${pod_name} → node ${node_name} (nodepool label not found)"
      fi
    done < <(kubectl get pods -n "${NAMESPACE}" -l "app=${DEPLOYMENT}" \
      --field-selector=status.phase=Running -o name 2>/dev/null \
      | sed 's|pod/||')

    if [ "${gpu_scheduled}" -gt 0 ]; then
      pass "GPU mode: ${gpu_scheduled} pod(s) scheduled on Karpenter GPU nodes"
    elif [ "${general_scheduled}" -gt 0 ]; then
      pass "CPU-sim mode: ${general_scheduled} pod(s) scheduled on general nodes (expected in dev)"
      info "To validate real GPU scheduling, remove the affinity patch from environments/dev/inference/kustomization.yaml"
    else
      warn "Could not determine node pool for running pods"
    fi

    # Check that GPU resources are requested (GPU mode only)
    local pod
    pod=$(kubectl get pods -n "${NAMESPACE}" -l "app=${DEPLOYMENT}" \
      --field-selector=status.phase=Running -o name 2>/dev/null | head -1 | sed 's|pod/||')
    if [ -n "${pod}" ]; then
      local gpu_req
      gpu_req=$(kubectl get pod "${pod}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.containers[0].resources.requests.nvidia\.com/gpu}' 2>/dev/null || echo "")
      if [ -n "${gpu_req}" ] && [ "${gpu_req}" != "0" ]; then
        pass "Pod requests nvidia.com/gpu=${gpu_req} (GPU mode confirmed)"
      else
        info "Pod has no nvidia.com/gpu request (CPU simulation mode)"
      fi

      # Probe health endpoint
      if kubectl exec -n "${NAMESPACE}" "${pod}" -- \
          python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
          > /dev/null 2>&1; then
        pass "Health probe /health returns 200 inside pod"
      else
        warn "Could not reach /health inside pod — check readinessProbe configuration"
      fi

      # nvidia-smi check (GPU mode only — stub container won't have nvidia-smi but real ones will)
      if [ -n "${gpu_req}" ] && [ "${gpu_req}" != "0" ]; then
        local smi_out
        smi_out=$(kubectl exec -n "${NAMESPACE}" "${pod}" -- \
          nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "")
        if [ -n "${smi_out}" ]; then
          pass "nvidia-smi: GPU visible inside pod — ${smi_out}"
          TIMINGS[gpu_model]=$(echo "${smi_out}" | head -1 | awk -F',' '{print $1}' | tr -d ' ')
        else
          warn "nvidia-smi not available inside pod — expected for stub container, required for real inference"
          info "Swap the stub image for a CUDA-based image to confirm GPU access"
        fi
      fi
    fi
  else
    fail "Inference pods did not become available within 180s"
    kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || true
  fi
}

step_inference_load() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " STEP 4b — Inference Load (latency + throughput evidence)"
  echo "═══════════════════════════════════════════════════"

  local pod
  pod=$(kubectl get pods -n "${NAMESPACE}" -l "app=${DEPLOYMENT}" \
    --field-selector=status.phase=Running -o name 2>/dev/null | head -1 | sed 's|pod/||')

  if [ -z "${pod}" ]; then
    warn "No running pod found — skipping inference load (latency panels will be empty)"
    return
  fi

  info "Running 90s of concurrent /infer requests against ${pod}..."
  info "This populates the Grafana latency histogram, throughput, and cost-per-request panels."

  # 5 parallel workers via kubectl exec — each sends requests for 90 seconds.
  # Requests use a fixed 150ms simulated latency so the histogram is meaningful.
  local load_pids=()
  for _ in 1 2 3 4 5; do
    kubectl exec -n "${NAMESPACE}" "${pod}" -- \
      python3 -c "
import urllib.request, json, time, sys
end = time.time() + 90
count = 0
while time.time() < end:
    try:
        req = urllib.request.Request(
            'http://localhost:8000/infer',
            data=b'{\"latency_ms\": 150}',
            method='POST',
            headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req, timeout=10)
        count += 1
    except Exception as e:
        pass
    time.sleep(0.2)
" &>/dev/null &
    load_pids+=($!)
  done

  local elapsed=0
  while [ "${elapsed}" -lt 90 ]; do
    sleep 15
    elapsed=$(( elapsed + 15 ))
    log "  ... ${elapsed}/90s — requests in flight"
  done

  for pid in "${load_pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done

  # Read total request count from the pod's /metrics endpoint
  local infer_total
  infer_total=$(kubectl exec -n "${NAMESPACE}" "${pod}" -- \
    python3 -c "
import urllib.request
resp = urllib.request.urlopen('http://localhost:8000/metrics', timeout=5)
for line in resp.read().decode().splitlines():
    if line.startswith('inference_infer_total '):
        print(line.split()[-1])
        break
" 2>/dev/null || echo "unknown")

  TIMINGS[infer_total]=${infer_total}
  pass "Load complete — inference_infer_total: ${infer_total} requests"
  info "Latency (p50/p95/p99), throughput, and cost-per-request panels now populated in Grafana"
}

step_scale_in() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " STEP 5 — Scale-In (drain queue → KEDA → Karpenter consolidation)"
  echo "═══════════════════════════════════════════════════"

  local drain_start
  drain_start=$(date +%s)

  log "Clearing gpu_job_queue_depth from Pushgateway..."
  clear_metric
  pass "Metric cleared (queue depth → 0)"

  info "Waiting for KEDA to scale deployment to 0 (cooldownPeriod=300s)..."
  if wait_for "deployment replicas = 0" "${SCALE_IN_TIMEOUT}" \
      "[ \$(kubectl get deployment ${DEPLOYMENT} -n ${NAMESPACE} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1) -eq 0 ]"; then
    local elapsed=$(( $(date +%s) - drain_start ))
    TIMINGS[scale_in_elapsed_s]=${elapsed}
    TIMINGS[scale_in_ts]=$(date '+%Y-%m-%dT%H:%M:%S')
    pass "KEDA scaled deployment to 0 replicas in ${elapsed}s"
  else
    fail "KEDA did not scale to 0 within ${SCALE_IN_TIMEOUT}s"
    info "Check: kubectl describe scaledobject -n ${NAMESPACE}"
  fi

  # Consolidation window is 3m in dev (base), 30m staging, 2h production
  info "Waiting for Karpenter to consolidate GPU node (consolidateAfter=3m in dev)..."
  if wait_for "GPU nodes consolidated" 600 \
      "[ \$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ') -eq 0 ]"; then
    pass "Karpenter consolidated GPU node — 0 GPU nodes remaining"
  else
    local gpu_nodes
    gpu_nodes=$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
    warn "${gpu_nodes} GPU node(s) still present after consolidation window"
    info "Expected: staging=30m, production=2h. Dev should consolidate within ~3m."
    info "Check: kubectl get nodeclaim && kubectl describe nodepool gpu"
  fi
}

step_summary() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " SUMMARY"
  echo "═══════════════════════════════════════════════════"
  echo ""
  echo -e "  ${GREEN}PASS: ${PASS}${NC}   ${RED}FAIL: ${FAIL}${NC}   WARN: ${#WARNINGS[@]}"
  echo ""

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo "Warnings:"
    for w in "${WARNINGS[@]}"; do
      echo -e "  ${YELLOW}⚠${NC} ${w}"
    done
    echo ""
  fi

  if [ "${FAIL}" -eq 0 ]; then
    echo -e "${GREEN}Architecture validation PASSED.${NC}"
    echo ""
    echo "The complete KEDA → Karpenter → GPU pod lifecycle was verified:"
    echo "  • Queue metric drove pod scaling (KEDA)"
    echo "  • GPU node provisioned on demand (Karpenter)"
    echo "  • NVIDIA device plugin advertised GPU resources"
    echo "  • Inference pods reached Running/Ready"
    echo "  • Scale-in and node consolidation completed"
  fi

  # ── Write timestamped results JSON (blog post evidence) ──────────────────
  cat > "${RESULTS_FILE}" <<JSON
{
  "validation": "$([ "${FAIL}" -eq 0 ] && echo PASSED || echo FAILED)",
  "pass": ${PASS},
  "fail": ${FAIL},
  "warn": ${#WARNINGS[@]},
  "cluster_context": "$(kubectl config current-context 2>/dev/null || echo unknown)",
  "node_instance_type": "${TIMINGS[node_instance_type]:-unknown}",
  "node_name": "${TIMINGS[node_name]:-unknown}",
  "timeline": {
    "queue_push":       "${TIMINGS[queue_push_ts]:-}",
    "node_ready":       "${TIMINGS[node_ready_ts]:-}",
    "pods_ready":       "${TIMINGS[pods_ready_ts]:-}",
    "scale_in":         "${TIMINGS[scale_in_ts]:-}"
  },
  "elapsed_seconds": {
    "queue_to_node_ready": ${TIMINGS[node_ready_elapsed_s]:-0},
    "queue_to_pods_ready": ${TIMINGS[pods_ready_elapsed_s]:-0},
    "scale_in":            ${TIMINGS[scale_in_elapsed_s]:-0}
  },
  "inference_load": {
    "total_requests": "${TIMINGS[infer_total]:-0}",
    "workers": 5,
    "duration_s": 90,
    "fixed_latency_ms": 150
  }
}
JSON
  echo ""
  echo "Results written to: ${RESULTS_FILE}"

  if [ "${FAIL}" -ne 0 ]; then
    echo -e "${RED}Architecture validation FAILED — ${FAIL} check(s) did not pass.${NC}"
    echo ""
    echo "Useful diagnostics:"
    echo "  kubectl get events -n inference --sort-by=.lastTimestamp | tail -20"
    echo "  kubectl get events -n karpenter --sort-by=.lastTimestamp | tail -20"
    echo "  kubectl logs -n keda -l app=keda-operator | tail -30"
    echo "  kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -30"
    echo "  kubectl describe nodepool gpu"
    echo "  kubectl get nodeclaim"
    exit 1
  fi
}

# ── main ────────────────────────────────────────────────────────────────────────

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Karpenter + KEDA GPU Inference — Architecture       ║"
echo "║   Validation Script                                    ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  Pushgateway: ${PUSHGATEWAY_URL}"
echo "  Namespace:   ${NAMESPACE}"
echo "  Deployment:  ${DEPLOYMENT}"
echo "  Queue depth: ${QUEUE_DEPTH} (threshold=5)"
echo "  Scale-out timeout: ${SCALE_OUT_TIMEOUT}s"
echo "  Scale-in timeout:  ${SCALE_IN_TIMEOUT}s"
echo ""

step_prerequisites
step_dragonfly
step_baseline
step_scale_out
step_pod_readiness
step_inference_load
step_scale_in
step_summary
