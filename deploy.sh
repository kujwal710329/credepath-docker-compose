#!/bin/bash
# deploy.sh — Runs ON the EC2 instance to deploy the application.
# Called by: GitHub Actions (CI/CD).
#
# Usage:
#   bash deploy.sh [environment] [image_tag]
#
# ── Single source of truth ────────────────────────────────────────────────────
# .env.config  — static values that never change (ports, region, JWT config…)
# deploy.sh    — ALL environment-specific config lives in the case block below
#                (NODE_ENV, bucket names, image names, Pinecone index, etc.)
#
# To change what gets deployed where, edit ONLY the case block below.
# ─────────────────────────────────────────────────────────────────────────────
#
# Prerequisites before calling:
#   1. .env.config must exist in the same directory (committed to git)
#   2. .env.secrets must exist in the same directory (written by caller)
#   3. AWS CLI and Docker Compose must be installed on the EC2

set -euo pipefail

ENVIRONMENT="${1:-staging}"
IMAGE_TAG="${2:-latest}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Deploying: environment=${ENVIRONMENT}  tag=${IMAGE_TAG}"

# ── Validate ──────────────────────────────────────────────────────────────────
if [ ! -f "${DEPLOY_DIR}/.env.config" ]; then
  echo "✗ .env.config not found. Run: git pull"
  exit 1
fi
if [ ! -f "${DEPLOY_DIR}/.env.secrets" ]; then
  echo "✗ .env.secrets not found. Caller must write it before running deploy.sh"
  exit 1
fi

# ── Environment-specific config ───────────────────────────────────────────────
# Edit here to change config per environment. These are written into .env at
# deploy time. NEXT_PUBLIC_API_BASE_URL is derived automatically from the EC2
# public IP (or passed explicitly via env var from the caller).
case "${ENVIRONMENT}" in
  staging)
    ENV_NODE_ENV="staging"
    ENV_BUCKET="credepath-prod"
    ENV_PINECONE_INDEX="acrapath-job-recommendations"
    ENV_SKIP_API_CHECK="true"
    ENV_BACKEND_IMAGE="acrapath/backendstag"
    ENV_FRONTEND_IMAGE="acrapath/frontendstag"
    ENV_ML_IMAGE="acrapath/jobsrecommenderstag"
    ENV_NGINX_CONFIG="nginx-staging.conf"
    # staging tags match prod ECR repo naming: latest, <sha>
    ;;
  production)
    ENV_NODE_ENV="production"
    ENV_BUCKET="acrapath-prod"
    ENV_PINECONE_INDEX="acrapath-prod-index"
    ENV_SKIP_API_CHECK="false"
    ENV_BACKEND_IMAGE="acrapath/backend"
    ENV_FRONTEND_IMAGE="acrapath/frontend"
    ENV_ML_IMAGE="acrapath/jobsrecommender"
    ENV_NGINX_CONFIG="nginx-production.conf"
    # production tags: latest, <sha>
    ;;
  *)
    echo "✗ Unknown environment '${ENVIRONMENT}'. Use: staging | production"
    exit 1
    ;;
esac

# ── Build .env ────────────────────────────────────────────────────────────────
echo "==> Building .env..."

cat "${DEPLOY_DIR}/.env.config" "${DEPLOY_DIR}/.env.secrets" > "${DEPLOY_DIR}/.env"
chmod 600 "${DEPLOY_DIR}/.env"
rm -f "${DEPLOY_DIR}/.env.secrets"

# Helper: update a key in .env (or append if missing)
set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${DEPLOY_DIR}/.env"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${DEPLOY_DIR}/.env"
  else
    echo "${key}=${val}" >> "${DEPLOY_DIR}/.env"
  fi
}

set_env "IMAGE_TAG"              "${IMAGE_TAG}"
set_env "NODE_ENV"               "${ENV_NODE_ENV}"
set_env "AWS_BUCKET_NAME"        "${ENV_BUCKET}"
set_env "PINECONE_INDEX_NAME"    "${ENV_PINECONE_INDEX}"
set_env "SKIP_API_KEY_CHECK"     "${ENV_SKIP_API_CHECK}"
set_env "BACKEND_IMAGE"          "${ENV_BACKEND_IMAGE}"
set_env "FRONTEND_IMAGE"         "${ENV_FRONTEND_IMAGE}"
set_env "ML_IMAGE"               "${ENV_ML_IMAGE}"
set_env "NGINX_CONFIG"           "${ENV_NGINX_CONFIG}"

# Derive S3 URL from bucket and region
AWS_REGION="$(grep '^AWS_REGION=' "${DEPLOY_DIR}/.env.config" | cut -d= -f2 | xargs)"
set_env "NEXT_PUBLIC_S3_BASE_URL" "https://${ENV_BUCKET}.s3.${AWS_REGION}.amazonaws.com"

# Derive public API URL dynamically from EC2's own public IP
# Caller-passed NEXT_PUBLIC_API_BASE_URL takes priority if set
if [ -n "${NEXT_PUBLIC_API_BASE_URL:-}" ]; then
  set_env "NEXT_PUBLIC_API_BASE_URL" "${NEXT_PUBLIC_API_BASE_URL}"
else
  # Try IMDSv2 first (required on most modern EC2 instances), fall back to IMDSv1
  IMDS_TOKEN="$(curl -s -X PUT --max-time 3 \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token 2>/dev/null || echo "")"
  if [ -n "${IMDS_TOKEN}" ]; then
    EC2_PUBLIC_IP="$(curl -s --max-time 3 \
      -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
      http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")"
  else
    EC2_PUBLIC_IP="$(curl -s --max-time 3 \
      http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")"
  fi
  if [ -n "${EC2_PUBLIC_IP}" ]; then
    set_env "NEXT_PUBLIC_API_BASE_URL" "http://${EC2_PUBLIC_IP}:5000/api/v1"
    echo "==> NEXT_PUBLIC_API_BASE_URL auto-set: http://${EC2_PUBLIC_IP}:5000/api/v1"
  else
    echo "⚠  Could not detect EC2 public IP. NEXT_PUBLIC_API_BASE_URL not updated."
  fi
fi

# ── ECR login ─────────────────────────────────────────────────────────────────
ECR_REGISTRY="$(grep '^ECR_REGISTRY=' "${DEPLOY_DIR}/.env.config" | cut -d= -f2 | xargs)"
export AWS_ACCESS_KEY_ID="$(grep '^AWS_ACCESS_KEY_ID=' "${DEPLOY_DIR}/.env" | cut -d= -f2-)"
export AWS_SECRET_ACCESS_KEY="$(grep '^AWS_SECRET_ACCESS_KEY=' "${DEPLOY_DIR}/.env" | cut -d= -f2-)"

echo "==> Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ── Pull images and restart ───────────────────────────────────────────────────
echo "==> Pulling images [tag: ${IMAGE_TAG}]..."
docker compose -f "${DEPLOY_DIR}/docker-compose.yml" pull

echo "==> Restarting services..."
docker compose -f "${DEPLOY_DIR}/docker-compose.yml" up -d --remove-orphans

echo "==> Cleaning up old images..."
docker image prune -f

echo "==> Deploy complete ✓"
docker compose -f "${DEPLOY_DIR}/docker-compose.yml" ps
