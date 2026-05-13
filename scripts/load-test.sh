#!/usr/bin/env bash
# load-test.sh — drives gpu_job_queue_depth via Prometheus Pushgateway to trigger
# the KEDA → Karpenter → GPU pod scaling chain.
#
# Usage:
#   ./scripts/load-test.sh [ramp|hold|drain|pulse|status]
#
#   ramp   — gradually increase queue depth from 0 to MAX_DEPTH (default 20)
#   hold   — set queue depth to MAX_DEPTH and hold for HOLD_SECONDS (default 300)
#   drain  — set queue depth to 0 (triggers scale-down + node consolidation)
#   pulse  — ramp → hold → drain in one shot (full lifecycle test)
#   status — print current metric value from Pushgateway
#
# Environment variables:
#   PUSHGATEWAY_URL   default: http://localhost:9091 (use kubectl port-forward first)
#   MAX_DEPTH         default: 20  (above the ScaledObject threshold of 5)
#   HOLD_SECONDS      default: 300 (5 min — long enough for pods to reach Running)
#   RAMP_STEPS        default: 5
#   RAMP_INTERVAL     default: 10  (seconds between steps)

set -euo pipefail

PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://localhost:9091}"
MAX_DEPTH="${MAX_DEPTH:-20}"
HOLD_SECONDS="${HOLD_SECONDS:-300}"
RAMP_STEPS="${RAMP_STEPS:-5}"
RAMP_INTERVAL="${RAMP_INTERVAL:-10}"
JOB="inference-load-test"
INSTANCE="load-generator"

# ── helpers ────────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*"; }

push_depth() {
  local depth=$1
  cat <<EOF | curl -s --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/${JOB}/instance/${INSTANCE}"
# HELP gpu_job_queue_depth Current depth of the GPU job queue
# TYPE gpu_job_queue_depth gauge
gpu_job_queue_depth{job="inference-load-test"} ${depth}
EOF
  log "Pushed gpu_job_queue_depth = ${depth}"
}

clear_metric() {
  curl -s -X DELETE "${PUSHGATEWAY_URL}/metrics/job/${JOB}/instance/${INSTANCE}"
  log "Cleared metric from Pushgateway (queue depth → 0)"
}

check_pushgateway() {
  if ! curl -sf "${PUSHGATEWAY_URL}/-/healthy" > /dev/null; then
    echo "ERROR: Pushgateway not reachable at ${PUSHGATEWAY_URL}"
    echo "Run first: kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring"
    exit 1
  fi
}

# ── commands ───────────────────────────────────────────────────────────────────

cmd_status() {
  log "Fetching current metric from Pushgateway..."
  curl -s "${PUSHGATEWAY_URL}/metrics" | grep gpu_job_queue_depth || log "No metric found (queue is empty)"
}

cmd_ramp() {
  check_pushgateway
  log "Ramping queue depth from 0 to ${MAX_DEPTH} over $((RAMP_STEPS * RAMP_INTERVAL))s..."
  local step=$(( MAX_DEPTH / RAMP_STEPS ))
  for i in $(seq 1 "${RAMP_STEPS}"); do
    local depth=$(( step * i ))
    push_depth "${depth}"
    sleep "${RAMP_INTERVAL}"
  done
  push_depth "${MAX_DEPTH}"
  log "Ramp complete. Queue depth = ${MAX_DEPTH}"
}

cmd_hold() {
  check_pushgateway
  push_depth "${MAX_DEPTH}"
  log "Holding queue depth at ${MAX_DEPTH} for ${HOLD_SECONDS}s..."
  log "Watch scaling: kubectl get pods -n inference -w"
  log "Watch nodes:   kubectl get nodes -l karpenter.sh/nodepool=gpu -w"

  local elapsed=0
  local interval=15
  while [ "${elapsed}" -lt "${HOLD_SECONDS}" ]; do
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
    local replicas
    replicas=$(kubectl get deployment inference-pod -n inference -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    local nodes
    nodes=$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log "  [${elapsed}/${HOLD_SECONDS}s] replicas=${replicas} gpu_nodes=${nodes} queue=${MAX_DEPTH}"
    push_depth "${MAX_DEPTH}"  # refresh — Pushgateway staleness default is 5m
  done
  log "Hold complete."
}

cmd_drain() {
  check_pushgateway
  log "Draining queue — setting depth to 0..."
  clear_metric
  log "Queue cleared. KEDA will scale down after cooldownPeriod (300s)."
  log "Karpenter will consolidate GPU nodes after consolidateAfter (30s dev / 2h prod)."
  log "Watch: kubectl get nodes -l karpenter.sh/nodepool=gpu -w"
}

cmd_pulse() {
  log "=== FULL LIFECYCLE PULSE TEST ==="
  log "This runs: ramp → hold (${HOLD_SECONDS}s) → drain"
  log ""
  cmd_ramp
  log ""
  cmd_hold
  log ""
  cmd_drain
  log ""
  log "=== Pulse complete. Monitor scale-down with validate-scaling.sh ==="
}

# ── main ───────────────────────────────────────────────────────────────────────

COMMAND="${1:-pulse}"

case "${COMMAND}" in
  ramp)   cmd_ramp   ;;
  hold)   cmd_hold   ;;
  drain)  cmd_drain  ;;
  pulse)  cmd_pulse  ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 [ramp|hold|drain|pulse|status]"
    exit 1
    ;;
esac
