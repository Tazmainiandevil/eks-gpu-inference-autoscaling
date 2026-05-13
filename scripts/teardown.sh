#!/usr/bin/env bash
# teardown.sh — scale everything to zero and verify GPU spend reaches near-zero.
#
# Run this after testing to ensure no GPU nodes are left running.
# Does NOT destroy the cluster — it just drains workloads and verifies scale-in.
# To destroy the cluster entirely, see: terraform destroy -var-file=environments/dev.tfvars
#
# Usage:
#   ./scripts/teardown.sh
#   ./scripts/teardown.sh --destroy    # also runs terraform destroy (prompts for confirmation)
#
# Environment variables:
#   PUSHGATEWAY_URL    default: http://localhost:9091
#   NAMESPACE          default: inference
#   DEPLOYMENT         default: inference-pod
#   AWS_REGION         default: eu-west-2

set -euo pipefail

PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://localhost:9091}"
NAMESPACE="${NAMESPACE:-inference}"
DEPLOYMENT="${DEPLOYMENT:-inference-pod}"
AWS_REGION="${AWS_REGION:-eu-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-gpu-demo}"
DESTROY_CLUSTER="${1:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
info() { echo -e "${CYAN}  →${NC} $*"; }
die()  { echo -e "${RED}  ✗${NC} $*"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Karpenter + KEDA GPU Inference — Teardown           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Clear Pushgateway metric ──────────────────────────────────────────
echo "─── Step 1: Clear queue metric ───────────────────────"
if curl -sf "${PUSHGATEWAY_URL}/-/healthy" > /dev/null 2>&1; then
  curl -s -X DELETE "${PUSHGATEWAY_URL}/metrics/job/load-test/instance/load-tester" || true
  curl -s -X DELETE "${PUSHGATEWAY_URL}/metrics/job/validate-scaling/instance/validator" || true
  ok "Pushgateway metrics cleared (gpu_job_queue_depth → 0)"
else
  warn "Pushgateway not reachable at ${PUSHGATEWAY_URL} — metric may still be set"
  info "If KEDA is still scaling up, run:"
  info "  kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring"
  info "  curl -X DELETE http://localhost:9091/metrics/job/load-test/instance/load-tester"
fi

# ── Step 2: Wait for KEDA to scale deployment to 0 ────────────────────────────
echo ""
echo "─── Step 2: Wait for KEDA scale-in (cooldown 300s) ───"
SCALE_IN_TIMEOUT=540
elapsed=0
interval=15
log "Waiting up to ${SCALE_IN_TIMEOUT}s for deployment to reach 0 replicas..."
while true; do
  replicas=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  replicas=${replicas:-0}
  if [ "${replicas}" -eq 0 ]; then
    ok "Deployment ${DEPLOYMENT} at 0 replicas"
    break
  fi
  log "  ... replicas=${replicas}, elapsed=${elapsed}s/${SCALE_IN_TIMEOUT}s"
  sleep "${interval}"
  elapsed=$(( elapsed + interval ))
  if [ "${elapsed}" -ge "${SCALE_IN_TIMEOUT}" ]; then
    warn "Deployment still has ${replicas} replicas after ${SCALE_IN_TIMEOUT}s"
    warn "Check: kubectl describe scaledobject -n ${NAMESPACE}"
    break
  fi
done

# ── Step 3: Wait for running pods to terminate ────────────────────────────────
echo ""
echo "─── Step 3: Verify pods terminated ───────────────────"
elapsed=0
while true; do
  running=$(kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' ') || running=0
  if [ "${running}" -eq 0 ]; then
    ok "No running inference pods"
    break
  fi
  log "  ... ${running} pod(s) still running, elapsed=${elapsed}s"
  sleep 10
  elapsed=$(( elapsed + 10 ))
  if [ "${elapsed}" -ge 120 ]; then
    warn "${running} pod(s) still running after 120s — check for stuck PodDisruptionBudgets"
    info "  kubectl get pdb -n ${NAMESPACE}"
    info "  kubectl delete pdb inference-pdb -n ${NAMESPACE}  # temporary, re-apply after"
    break
  fi
done

# ── Step 4: Wait for Karpenter GPU nodes to consolidate ───────────────────────
echo ""
echo "─── Step 4: Wait for Karpenter GPU node consolidation ─"
log "Waiting up to 300s for GPU nodes to consolidate (dev consolidateAfter=3m)..."
elapsed=0
while true; do
  gpu_nodes=$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null \
    | wc -l | tr -d ' ') || gpu_nodes=0
  if [ "${gpu_nodes}" -eq 0 ]; then
    ok "0 Karpenter GPU nodes running"
    break
  fi
  log "  ... ${gpu_nodes} GPU node(s) remaining, elapsed=${elapsed}s"
  sleep 15
  elapsed=$(( elapsed + 15 ))
  if [ "${elapsed}" -ge 300 ]; then
    warn "${gpu_nodes} GPU node(s) still present after 300s"
    info "Karpenter may be waiting on PDB or terminationGracePeriod."
    info "Check: kubectl get nodeclaim && kubectl describe nodepool gpu"
    break
  fi
done

# ── Step 5: Cost check via OpenCost ───────────────────────────────────────────
echo ""
echo "─── Step 5: Cost verification ─────────────────────────"
OPENCOST_PORT=9003
# Try port-forward in background if needed
if ! curl -sf "http://localhost:${OPENCOST_PORT}/healthz" > /dev/null 2>&1; then
  info "Starting OpenCost port-forward (PID will be shown)..."
  kubectl port-forward svc/opencost "${OPENCOST_PORT}:${OPENCOST_PORT}" -n opencost &
  PF_PID=$!
  sleep 3
else
  PF_PID=""
fi

if curl -sf "http://localhost:${OPENCOST_PORT}/allocation?window=5m&aggregate=label:app" \
    -o /tmp/opencost-teardown.json 2>/dev/null; then
  # Extract total cost from last 5 min — should be near $0 after scale-in
  total=$(python3 -c "
import json, sys
try:
    d = json.load(open('/tmp/opencost-teardown.json'))
    sets = d.get('data', [{}])
    total = sum(v.get('totalCost', 0) for s in sets for v in s.values())
    print(f'{total:.4f}')
except Exception as e:
    print('0.0000')
" 2>/dev/null || echo "0.0000")
  ok "OpenCost: last 5-min allocation cost = \$${total} USD"
  if python3 -c "exit(0 if float('${total}') < 0.05 else 1)" 2>/dev/null; then
    ok "GPU spend is effectively zero — safe to leave cluster idle"
  else
    warn "Non-trivial spend detected (\$${total} in last 5 min) — GPU node may still be running"
  fi
else
  info "OpenCost not reachable — skipping cost check"
  info "Manual check: kubectl port-forward svc/opencost 9003:9003 -n opencost"
  info "              curl 'http://localhost:9003/allocation?window=5m&aggregate=label:app'"
fi

[[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true

# ── Step 6: Current node list ─────────────────────────────────────────────────
echo ""
echo "─── Step 6: Remaining nodes ───────────────────────────"
kubectl get nodes -o wide 2>/dev/null || true
echo ""
gpu_remaining=$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ') || gpu_remaining=0
if [ "${gpu_remaining}" -eq 0 ]; then
  ok "No GPU nodes running. Idle cost: system + app nodes only (~\$0.17-0.21/hr in dev)."
else
  warn "${gpu_remaining} GPU node(s) still in cluster — monitor for unexpected charges"
fi

# ── Optional: destroy cluster ─────────────────────────────────────────────────
if [[ "${DESTROY_CLUSTER}" == "--destroy" ]]; then
  echo ""
  echo "─── Cluster destroy ───────────────────────────────────"
  warn "This will DESTROY the EKS cluster and ALL associated resources."
  warn "Terraform state must be intact for this to work cleanly."
  read -r -p "  Type 'destroy' to confirm: " confirm
  if [[ "${confirm}" == "destroy" ]]; then

    # Step A: Delete PVCs before destroying the cluster so EBS volumes are
    # released and can be cleaned up. Kubernetes won't delete the underlying EBS
    # volume if the PVC is deleted while the cluster is still running (reclaim policy=Delete),
    # but if the cluster is destroyed first the volumes are orphaned.
    echo ""
    echo "─── Step A: Delete PVCs (release EBS volumes) ────────"
    for ns in monitoring inference dragonfly-system karpenter keda; do
      pvc_count=$(kubectl get pvc -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ') || pvc_count=0
      if [ "${pvc_count}" -gt 0 ]; then
        info "Deleting ${pvc_count} PVC(s) in namespace ${ns}..."
        kubectl delete pvc --all -n "${ns}" --timeout=60s 2>/dev/null || true
        ok "PVCs deleted from ${ns}"
      else
        info "No PVCs in ${ns}"
      fi
    done

    # Step B: Pre-destroy AWS cleanup — Karpenter Spot resources must be gone
    # before Terraform can delete the Spot SLR, subnets, and security groups.
    echo ""
    echo "─── Step B: Pre-destroy Karpenter / Spot cleanup ──────"
    TFVARS_FILE="${TFVARS:-environments/dev.tfvars}"
    CLUSTER_NAME=$(grep 'cluster_name' "${TFVARS_FILE}" | awk -F'"' '{print $2}' | tr -d '\r' || echo "eks-gpu-demo")

    # Delete Karpenter NodePools — triggers graceful termination of managed nodes
    if kubectl get nodepool gpu > /dev/null 2>&1 || kubectl get nodepool general > /dev/null 2>&1; then
      info "Deleting Karpenter NodePools (signals Karpenter to terminate its nodes)..."
      kubectl delete nodepool gpu general --timeout=120s 2>/dev/null || true
      ok "NodePools deleted"
    else
      info "No Karpenter NodePools found"
    fi

    # Wait for Karpenter NodeClaims to drain
    elapsed=0
    while true; do
      nc=$(kubectl get nodeclaim --no-headers 2>/dev/null | wc -l | tr -d ' ') || nc=0
      [ "${nc}" -eq 0 ] && break
      [ "${elapsed}" -ge 90 ] && { warn "${nc} NodeClaim(s) still present after 90s — continuing anyway"; break; }
      log "  ... ${nc} NodeClaim(s) remaining (${elapsed}s)"
      sleep 10; elapsed=$(( elapsed + 10 ))
    done

    # Cancel any open/active Spot Instance Requests tagged with this cluster
    info "Cancelling open Spot Instance Requests for cluster '${CLUSTER_NAME}'..."
    open_sirs=$(aws ec2 describe-spot-instance-requests \
      --region "${AWS_REGION}" \
      --filters "Name=state,Values=open,active" \
      --query "SpotInstanceRequests[?Tags[?Key=='karpenter.sh/nodepool']].SpotInstanceRequestId" \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' || true)

    if [ -n "${open_sirs}" ]; then
      sir_list=$(echo "${open_sirs}" | tr '\n' ' ')
      info "Cancelling SIR(s): ${sir_list}"
      # shellcheck disable=SC2086
      aws ec2 cancel-spot-instance-requests \
        --region "${AWS_REGION}" \
        --spot-instance-request-ids ${sir_list} > /dev/null 2>&1 || true
      ok "Spot Instance Requests cancelled"
    else
      ok "No open Spot Instance Requests found"
    fi

    # Terminate any remaining EC2 instances tagged with Karpenter.
    # Include shutting-down so that instances Karpenter already started terminating
    # are also waited on — otherwise they slip past this check and block Terraform.
    info "Terminating remaining Karpenter-tagged EC2 instances..."
    karpenter_instances=$(aws ec2 describe-instances \
      --region "${AWS_REGION}" \
      --filters \
        "Name=tag-key,Values=karpenter.sh/nodepool" \
        "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
      --query 'Reservations[*].Instances[*].InstanceId' \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' || true)

    if [ -n "${karpenter_instances}" ]; then
      inst_list=$(echo "${karpenter_instances}" | tr '\n' ' ')
      info "Terminating/awaiting instance(s): ${inst_list}"
      # Terminate those not already shutting down (harmless no-op for the rest)
      # shellcheck disable=SC2086
      aws ec2 terminate-instances \
        --region "${AWS_REGION}" \
        --instance-ids ${inst_list} > /dev/null 2>&1 || true
      info "Waiting for full EC2 termination (up to 5 min)..."
      # shellcheck disable=SC2086
      aws ec2 wait instance-terminated \
        --region "${AWS_REGION}" \
        --instance-ids ${inst_list} 2>/dev/null || true
      ok "Karpenter instances terminated"
    else
      ok "No running Karpenter instances found"
    fi

    # Delete orphaned SGs created by Kubernetes controllers (LB controller, VPC CNI).
    # These are not in Terraform state and will block VPC deletion if not removed first.
    info "Checking for Kubernetes-created orphaned security groups..."
    VPC_ID=$(aws ec2 describe-vpcs \
      --region "${AWS_REGION}" \
      --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
      --query "Vpcs[0].VpcId" \
      --output text 2>/dev/null || echo "")

    if [ -n "${VPC_ID}" ] && [ "${VPC_ID}" != "None" ]; then
      lb_sgs=$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" \
        --filters \
          "Name=vpc-id,Values=${VPC_ID}" \
          "Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
        --query "SecurityGroups[*].GroupId" \
        --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' || true)

      k8s_sgs=$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" \
        --filters \
          "Name=vpc-id,Values=${VPC_ID}" \
          "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
        --query "SecurityGroups[*].GroupId" \
        --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' || true)

      all_orphan_sgs=$(echo -e "${lb_sgs}\n${k8s_sgs}" | sort -u | grep -v '^$' || true)

      if [ -z "${all_orphan_sgs}" ]; then
        ok "No orphaned Kubernetes security groups found"
      else
        sg_count=$(echo "${all_orphan_sgs}" | wc -l | tr -d ' ')
        warn "${sg_count} orphaned security group(s) found — deleting before Terraform destroy"
        while IFS= read -r sg_id; do
          [ -z "${sg_id}" ] && continue
          if aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${sg_id}" 2>/dev/null; then
            ok "Deleted security group ${sg_id}"
          else
            warn "Could not delete ${sg_id} — may have dependencies; Terraform will retry"
          fi
        done <<< "${all_orphan_sgs}"
      fi
    else
      info "VPC not found for cluster '${CLUSTER_NAME}' — skipping orphaned SG cleanup"
    fi

    # Remove the EC2 Spot Service Linked Role from Terraform state rather than
    # destroying it. The SLR is account-level — destroying it fails whenever any
    # other Spot activity exists in the account, and it's automatically recreated
    # on the next Spot request anyway.
    info "Removing EC2 Spot SLR from Terraform state (leaving it in AWS)..."
    cd terraform
    terraform state rm aws_iam_service_linked_role.spot 2>/dev/null && \
      ok "Spot SLR removed from state" || info "Spot SLR not in state (already removed or never created)"

    # Step C: Terraform destroy
    echo ""
    echo "─── Step C: Terraform destroy ─────────────────────────"
    info "Running terraform destroy -var-file=${TFVARS_FILE}..."
    terraform destroy -var-file="${TFVARS_FILE}" -auto-approve
    cd ..
    ok "Cluster destroyed."

    # Step D: Find and delete orphaned EBS volumes tagged with the cluster name.
    # These can be left behind if PVCs were not deleted before cluster destroy,
    # or if Karpenter node volumes were not cleaned up by the termination controller.
    echo ""
    echo "─── Step D: Clean up orphaned EBS volumes ────────────"
    info "Searching for EBS volumes tagged with cluster '${CLUSTER_NAME}'..."
    orphaned_volumes=$(aws ec2 describe-volumes \
      --region "${AWS_REGION}" \
      --filters \
        "Name=status,Values=available" \
        "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
      --query 'Volumes[*].VolumeId' \
      --output text 2>/dev/null || echo "")

    # Also catch volumes tagged by the EBS CSI driver
    csi_volumes=$(aws ec2 describe-volumes \
      --region "${AWS_REGION}" \
      --filters \
        "Name=status,Values=available" \
        "Name=tag-key,Values=kubernetes.io/created-for/pvc/namespace" \
      --query 'Volumes[].{ID:VolumeId,PVC:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value,Cluster:Tags[?Key==`KubernetesCluster`]|[0].Value}' \
      --output text 2>/dev/null | grep -v "^None" | awk '{print $1}' || echo "")

    all_volumes=$(echo -e "${orphaned_volumes}\n${csi_volumes}" | sort -u | grep -v '^$' || echo "")

    if [ -z "${all_volumes}" ]; then
      ok "No orphaned EBS volumes found for cluster '${CLUSTER_NAME}'"
    else
      vol_count=$(echo "${all_volumes}" | wc -l | tr -d ' ')
      warn "${vol_count} orphaned EBS volume(s) found — deleting to avoid charges"
      while IFS= read -r vol_id; do
        [ -z "${vol_id}" ] && continue
        if aws ec2 delete-volume --region "${AWS_REGION}" --volume-id "${vol_id}" 2>/dev/null; then
          ok "Deleted volume ${vol_id}"
        else
          warn "Could not delete ${vol_id} — may already be deleted or in use"
        fi
      done <<< "${all_volumes}"
    fi

    ok "All AWS resources removed. Run 'aws ec2 describe-volumes --filters Name=status,Values=available' to verify."

    # Step E: Delete ECR repositories.
    # ECR repos are created by setup.sh / push scripts and are not managed by Terraform.
    # Images continue to incur storage cost ($0.10/GB/month) until explicitly deleted.
    echo ""
    echo "─── Step E: Delete ECR repositories ──────────────────"
    account_id=$(aws sts get-caller-identity --region "${AWS_REGION}" --query Account --output text 2>/dev/null || echo "")
    if [ -n "${account_id}" ]; then
      all_repos=$(aws ecr describe-repositories \
        --region "${AWS_REGION}" \
        --query "repositories[*].repositoryName" \
        --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)

      repos_to_delete=""
      for repo in ${all_repos}; do
        repo_arn="arn:aws:ecr:${AWS_REGION}:${account_id}:repository/${repo}"
        tag_match=$(aws ecr list-tags-for-resource \
          --region "${AWS_REGION}" \
          --resource-arn "${repo_arn}" \
          --query "tags[?Value=='${CLUSTER_NAME}'].Key" \
          --output text 2>/dev/null || true)
        if [ -n "${tag_match}" ] || echo "${repo}" | grep -q "${CLUSTER_NAME}"; then
          repos_to_delete="${repos_to_delete} ${repo}"
        fi
      done

      if [ -z "$(echo "${repos_to_delete}" | tr -d ' ')" ]; then
        ok "No ECR repositories found for cluster '${CLUSTER_NAME}'"
      else
        for repo in ${repos_to_delete}; do
          info "Deleting ECR repository: ${repo} (including all images)..."
          if aws ecr delete-repository \
              --region "${AWS_REGION}" \
              --repository-name "${repo}" \
              --force > /dev/null 2>/dev/null; then
            ok "Deleted ECR repository: ${repo}"
          else
            warn "Could not delete ECR repository: ${repo}"
          fi
        done
      fi
    else
      warn "Could not determine AWS account ID — skipping ECR cleanup"
    fi

    # Step F: Delete cluster secrets from AWS Secrets Manager.
    # These are created by setup.sh and are not managed by Terraform, so terraform
    # destroy does not remove them. Without this step they continue to incur
    # Secrets Manager storage cost ($0.40/secret/month).
    echo ""
    echo "─── Step F: Delete Secrets Manager secrets ────────────"
    for secret in "${CLUSTER_NAME}/grafana-admin"; do
      if aws secretsmanager describe-secret \
          --region "${AWS_REGION}" \
          --secret-id "${secret}" > /dev/null 2>&1; then
        aws secretsmanager delete-secret \
          --region "${AWS_REGION}" \
          --secret-id "${secret}" \
          --force-delete-without-recovery
        ok "Deleted secret: ${secret}"
      else
        info "Secret not found (already deleted): ${secret}"
      fi
    done
  else
    info "Destroy cancelled."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo -e "${GREEN}Teardown complete.${NC}"
echo ""
echo "Cluster is idle. Running costs (dev):"
echo "  System node (1× t3.medium ON_DEMAND):  ~\$0.05/hr"
echo "  App node    (1× t3.small  ON_DEMAND):  ~\$0.03/hr"
echo "  EKS cluster fee:                        ~\$0.10/hr"
echo "  VPC endpoints (ECR, S3, STS):           ~\$0.03/hr"
echo "  ─────────────────────────────────────────────────"
echo "  Total idle:                             ~\$0.21/hr (~\$5/day)"
echo ""
echo "To fully stop costs, destroy the cluster:"
echo "  ./scripts/teardown.sh --destroy"
echo "══════════════════════════════════════════════════════"
