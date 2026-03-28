#!/bin/bash
# deploy.sh — Runs ON the EC2 instance to deploy the application.
# Called by: GitHub Actions (CI/CD) or start.sh (local SSH deploy).
#
# Usage:
#   bash deploy.sh [environment] [image_tag]
#
# Prerequisites before calling:
#   1. .env.config must exist in the same directory (committed to git)
#   2. .env.secrets must exist in the same directory (written by caller)
#   3. AWS CLI and Docker Compose must be installed on the EC2
#
# Environment-specific config is centralized here — edit this file when
# you need to change bucket names, Pinecone indexes, etc. per environment.

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
# This is the single place to update per-environment non-sensitive config.
# Values here override anything in .env.config.
# NEXT_PUBLIC_API_BASE_URL is omitted here — pass it via env var from the caller
# (GitHub Actions secret or start.sh prompt) since it contains the EC2 IP.
case "${ENVIRONMENT}" in
  staging)
    ENV_NODE_ENV="development"
    ENV_BUCKET="credepath-staging"
    ENV_PINECONE_INDEX="acrapath-job-recommendations-staging"
    ENV_SKIP_API_CHECK="true"
    ;;
  production)
    ENV_NODE_ENV="production"
    ENV_BUCKET="credepath-prod"
    ENV_PINECONE_INDEX="acrapath-job-recommendations"
    ENV_SKIP_API_CHECK="false"
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

# Derive S3 URL from bucket and region
AWS_REGION="$(grep '^AWS_REGION=' "${DEPLOY_DIR}/.env.config" | cut -d= -f2 | xargs)"
set_env "NEXT_PUBLIC_S3_BASE_URL" "https://${ENV_BUCKET}.s3.${AWS_REGION}.amazonaws.com"

# Override public API URL if caller passed it (EC2 IP differs per environment)
if [ -n "${NEXT_PUBLIC_API_BASE_URL:-}" ]; then
  set_env "NEXT_PUBLIC_API_BASE_URL" "${NEXT_PUBLIC_API_BASE_URL}"
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
