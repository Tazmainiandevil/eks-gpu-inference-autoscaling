#!/usr/bin/env bash
# setup.sh — one-shot bootstrap for the Karpenter + KEDA GPU inference demo.
#
# What it does:
#   1. Validates prerequisites (aws, terraform, kubectl, docker, git)
#   2. Derives AWS account ID and ECR registry URL
#   3. Replaces YOUR_ORG in ArgoCD manifests with the current git remote org
#   4. Replaces ECR_REGISTRY_PLACEHOLDER in platform/dragonfly/values.yaml and containerd-config-daemonset.yaml
#   5. Patches ESO ClusterSecretStore region and ExternalSecret cluster-name key prefix
#   6. Creates the Grafana admin secret in AWS Secrets Manager (once — never overwrites)
#   7. Replaces CLUSTER_ID_PLACEHOLDER in platform/opencost/values.yaml
#   8. Builds and pushes the inference stub image to ECR
#   9. Patches environment overlay image refs with account/region
#  10. Prints next steps
#
# Usage:
#   ./scripts/setup.sh [--env dev|staging|production] [--skip-image]
#
# Environment variables (override defaults):
#   AWS_REGION        default: eu-west-2
#   CLUSTER_NAME      default: read from environments/dev.tfvars
#   IMAGE_TAG         default: git short SHA

set -euo pipefail

ENV="dev"
SKIP_IMAGE="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV="${2:-dev}"; shift 2 ;;
    --skip-image) SKIP_IMAGE="true"; shift ;;
    *)            die "Unknown argument: $1" ;;
  esac
done

TFVARS="terraform/environments/${ENV}.tfvars"
AWS_REGION="${AWS_REGION:-eu-west-2}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"

# ── colours ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}  →${NC} $*"; }
ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()   { echo -e "${RED}  ✗ ERROR:${NC} $*"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Karpenter + KEDA GPU Inference — Setup              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Prerequisites ──────────────────────────────────────────────────────
info "Checking prerequisites..."

for cmd in aws terraform kubectl docker git; do
  if command -v "${cmd}" &>/dev/null; then
    ok "${cmd} found ($(${cmd} --version 2>&1 | head -1))"
  else
    die "${cmd} not found — install it and re-run setup.sh"
  fi
done

# ── Step 2: Derive AWS account + ECR registry ──────────────────────────────────
info "Resolving AWS identity..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "Could not call aws sts get-caller-identity — check your AWS credentials"
ok "AWS account: ${AWS_ACCOUNT_ID}  region: ${AWS_REGION}"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ok "ECR registry: ${ECR_REGISTRY}"

# ── Step 3: Derive cluster name from tfvars ────────────────────────────────────
if [[ -f "${TFVARS}" ]]; then
  CLUSTER_NAME=$(grep '^cluster_name' "${TFVARS}" | sed 's/.*= *"\(.*\)"/\1/' | tr -d ' \r')
  ok "Cluster name (from ${TFVARS}): ${CLUSTER_NAME}"
else
  CLUSTER_NAME="eks-gpu-demo"
  warn "${TFVARS} not found — using default cluster name: ${CLUSTER_NAME}"
fi

# ── Step 4: Derive GitHub org from git remote ──────────────────────────────────
info "Deriving GitHub org from git remote..."
GIT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "${GIT_REMOTE}" =~ github\.com[:/]([^/]+)/ ]]; then
  GITHUB_ORG="${BASH_REMATCH[1]}"
  ok "GitHub org: ${GITHUB_ORG}"
else
  warn "Could not detect GitHub org from remote: ${GIT_REMOTE}"
  read -r -p "  Enter your GitHub org/username: " GITHUB_ORG
fi

# ── Step 5: Replace YOUR_ORG and YOUR_ENV in ArgoCD manifests ─────────────────
info "Replacing YOUR_ORG → ${GITHUB_ORG}, YOUR_ENV → ${ENV} in ArgoCD manifests..."
ARGOCD_FILES=(
  argocd/app-of-apps.yaml
  argocd/applicationset-platform-helm.yaml
  argocd/applicationset-platform-kustomize.yaml
  argocd/applicationset-security.yaml
  argocd/applicationset-apps.yaml
  argocd/containerd-config-application.yaml
)
for f in "${ARGOCD_FILES[@]}"; do
  changed=false
  if grep -q 'YOUR_ORG' "${f}" 2>/dev/null; then
    sed -i "s|YOUR_ORG|${GITHUB_ORG}|g" "${f}"
    changed=true
  fi
  if grep -q 'YOUR_ENV' "${f}" 2>/dev/null; then
    sed -i "s|YOUR_ENV|${ENV}|g" "${f}"
    changed=true
  fi
  if ${changed}; then
    ok "Patched ${f}"
  else
    info "${f} — already configured"
  fi
done

# ── Step 6: Replace ECR placeholder in Dragonfly values and DaemonSet ─────────
info "Patching Dragonfly ECR registry..."
DRAGONFLY_FILES=(
  "platform/dragonfly/values.yaml"
  "platform/dragonfly/containerd-config/containerd-config-daemonset.yaml"
  "platform/knative-serving/config-deployment.yaml"
  "environments/${ENV}/values/dragonfly-values.yaml"
)
for f in "${DRAGONFLY_FILES[@]}"; do
  if grep -q 'ECR_REGISTRY_PLACEHOLDER' "${f}"; then
    sed -i "s|ECR_REGISTRY_PLACEHOLDER|${ECR_REGISTRY}|g" "${f}"
    ok "Patched ${f} with ${ECR_REGISTRY}"
  else
    info "${f} — ECR registry already set"
  fi
done

# ── Step 7: Patch External Secrets Operator config ────────────────────────────
info "Patching ESO ClusterSecretStore region and ExternalSecret cluster name..."
ESO_STORE="platform/external-secrets/cluster-secret-store.yaml"
ESO_GRAFANA="platform/monitoring-secrets/grafana-external-secret.yaml"

if grep -q 'YOUR_AWS_REGION' "${ESO_STORE}"; then
  sed -i "s|YOUR_AWS_REGION|${AWS_REGION}|g" "${ESO_STORE}"
  ok "Patched ${ESO_STORE} → region: ${AWS_REGION}"
else
  info "${ESO_STORE} — region already set"
fi

if grep -q 'YOUR_CLUSTER_NAME' "${ESO_GRAFANA}"; then
  sed -i "s|YOUR_CLUSTER_NAME|${CLUSTER_NAME}|g" "${ESO_GRAFANA}"
  ok "Patched ${ESO_GRAFANA} → key prefix: ${CLUSTER_NAME}/"
else
  info "${ESO_GRAFANA} — cluster name already set"
fi

# ── Step 7b: Create Grafana admin secret in AWS Secrets Manager ───────────────
# ESO reads this secret to create the grafana-admin Kubernetes Secret in the
# monitoring namespace. Grafana's existingSecret config then reads it at startup.
# The secret is created once and never overwritten by subsequent setup.sh runs.
info "Checking for Grafana admin secret in Secrets Manager..."
GRAFANA_SECRET_NAME="${CLUSTER_NAME}/grafana-admin"
if aws secretsmanager describe-secret \
    --secret-id "${GRAFANA_SECRET_NAME}" \
    --region "${AWS_REGION}" > /dev/null 2>&1; then
  ok "Grafana admin secret already exists: ${GRAFANA_SECRET_NAME}"
else
  # Generate a 20-char random password (alphanumeric only — safe for all consumers)
  GRAFANA_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20; echo)
  aws secretsmanager create-secret \
    --name "${GRAFANA_SECRET_NAME}" \
    --description "Grafana admin credentials for EKS cluster ${CLUSTER_NAME}" \
    --secret-string "{\"username\":\"admin\",\"password\":\"${GRAFANA_PASSWORD}\"}" \
    --region "${AWS_REGION}" \
    --output text > /dev/null
  ok "Created secret: ${GRAFANA_SECRET_NAME}"
  echo ""
  echo -e "  ${YELLOW}  Save this password — it will not be shown again:${NC}"
  echo "    Grafana admin password: ${GRAFANA_PASSWORD}"
  echo "    (also stored in: aws secretsmanager get-secret-value --secret-id ${GRAFANA_SECRET_NAME})"
  echo ""
fi

# ── Step 7c: Patch Karpenter environment config ───────────────────────────────
info "Patching Karpenter values and NodeClass selectors..."
KARPENTER_FILES=(
  "environments/${ENV}/values/karpenter-values.yaml"
  "environments/${ENV}/karpenter/kustomization.yaml"
)
for f in "${KARPENTER_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    if grep -q 'YOUR_CLUSTER_NAME' "${f}"; then
      sed -i "s|YOUR_CLUSTER_NAME|${CLUSTER_NAME}|g" "${f}"
      ok "Patched ${f} → ${CLUSTER_NAME}"
    else
      info "${f} — cluster name already set"
    fi
  fi
done

# ── Step 8: Replace cluster ID in OpenCost values ────────────────────────────
info "Patching OpenCost cluster ID..."
OPENCOST_VALUES="platform/opencost/values.yaml"
if grep -q 'CLUSTER_ID_PLACEHOLDER' "${OPENCOST_VALUES}"; then
  sed -i "s|CLUSTER_ID_PLACEHOLDER|${CLUSTER_NAME}|g" "${OPENCOST_VALUES}"
  ok "Patched ${OPENCOST_VALUES} with clusterID: ${CLUSTER_NAME}"
else
  info "${OPENCOST_VALUES} — cluster ID already set"
fi

# ── Step 8b: Patch environment overlays with ECR account/region ───────────────
# The base apps/inference/ keeps REGISTRY_PLACEHOLDER (safe for public repos).
# Account-specific ECR image goes in the environment overlays only.
info "Updating environment overlay image references (inference + knative-inference)..."
for OVERLAY_FILE in \
    "environments/${ENV}/inference/kustomization.yaml" \
    "environments/${ENV}/knative-inference/kustomization.yaml"; do
  if [[ -f "${OVERLAY_FILE}" ]]; then
    sed -i "s|YOUR_AWS_ACCOUNT_ID|${AWS_ACCOUNT_ID}|g" "${OVERLAY_FILE}"
    sed -i "s|YOUR_AWS_REGION|${AWS_REGION}|g" "${OVERLAY_FILE}"
    ok "Patched ${OVERLAY_FILE} → ${ECR_REGISTRY}"
  else
    warn "Overlay not found: ${OVERLAY_FILE} — skipping"
  fi
done

# ── Step 9: Build and push stub image ─────────────────────────────────────────
ECR_REPO="${ECR_REGISTRY}/inference-stub"
IMAGE_URI="${ECR_REPO}:${IMAGE_TAG}"

if [[ "${SKIP_IMAGE}" == "false" ]]; then
  info "Ensuring ECR repository exists..."
  aws ecr describe-repositories --repository-names inference-stub --region "${AWS_REGION}" \
    --output text > /dev/null 2>&1 \
    || aws ecr create-repository --repository-name inference-stub \
         --region "${AWS_REGION}" \
         --tags Key=cluster,Value="${CLUSTER_NAME}" \
         --output text > /dev/null
  ok "ECR repository: inference-stub"

  info "Authenticating Docker to ECR..."
  # Capture password first to avoid BrokenPipeError from AWS CLI when docker login
  # closes the pipe before the full token is consumed (common in WSL2 environments).
  ECR_PASSWORD=$(aws ecr get-login-password --region "${AWS_REGION}")
  echo "${ECR_PASSWORD}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}" > /dev/null
  ok "Docker authenticated to ECR"

  info "Building inference stub image..."
  docker build -t "${IMAGE_URI}" apps/inference/stub/
  ok "Built ${IMAGE_URI}"

  info "Pushing image to ECR..."
  docker push "${IMAGE_URI}"
  # Also tag and push :latest for ArgoCD
  docker tag "${IMAGE_URI}" "${ECR_REPO}:latest"
  docker push "${ECR_REPO}:latest"
  ok "Pushed ${IMAGE_URI} and :latest"
else
  info "Skipping image build and push (--skip-image)"
fi

# ── Step 10: Summary ──────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo -e "${GREEN}Setup complete.${NC}"
echo ""
echo "Changes made:"
echo "  • ArgoCD manifests: YOUR_ORG → ${GITHUB_ORG}"
echo "  • Dragonfly:        ECR registry wired in values.yaml + containerd-config-daemonset.yaml (${ECR_REGISTRY})"
echo "  • Karpenter:        cluster name + NodeClass selectors set (${CLUSTER_NAME})"
echo "  • OpenCost:         cluster ID set (${CLUSTER_NAME})"
echo "  • ESO:              ClusterSecretStore region set (${AWS_REGION}), ExternalSecret cluster name set"
echo "  • Secrets Manager:  ${CLUSTER_NAME}/grafana-admin created (or already existed)"
echo "  • Overlays:         inference + knative-inference image refs set (${ECR_REGISTRY})"
if [[ "${SKIP_IMAGE}" == "false" ]]; then
  echo "  • Stub image:       pushed to ${ECR_REPO}:latest"
else
  echo "  • Stub image:       skipped (--skip-image)"
fi
echo ""
echo "Next steps:"
echo "  1. Review and commit the patched files:"
echo "       git diff"
echo "       git add -p && git commit -m 'chore: apply setup.sh configuration'"
echo "       git push"
echo ""
echo "  2. Run Terraform:"
echo "       cd terraform"
echo "       terraform init"
echo "       terraform apply -var-file=environments/${ENV}.tfvars"
echo "       cd .."
echo ""
echo "  3. Update kubeconfig:"
echo "       aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"
echo ""
echo "  4. Install ArgoCD and bootstrap the stack:"
echo "       kubectl create namespace argocd"
echo "       kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
echo "       kubectl wait --for=condition=available deployment -n argocd --all --timeout=120s"
echo "       kubectl apply -f argocd/app-of-apps.yaml"
echo ""
echo "  5. Run the end-to-end validation:"
echo "       kubectl port-forward svc/pushgateway-prometheus-pushgateway 9091:9091 -n monitoring &"
echo "       ./scripts/validate-scaling.sh"
echo ""
echo "  6. View cost and scaling dashboard:"
echo "       kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &"
echo "       open http://localhost:3000"
echo ""
echo "  When done, run teardown to scale to zero and verify cost:"
echo "       ./scripts/teardown.sh"
echo "══════════════════════════════════════════════════════"
