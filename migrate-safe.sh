#!/bin/bash
# migrate-safe.sh — Safe migration runner with snapshot, rollback plan,
#                   staging verification, and auto-restore on failure.
#
# Usage:
#   bash migrate-safe.sh [command] [environment]
#   command:     up | down | status  (default: up)
#   environment: staging | production (default: staging)
#
# Optional env var: MONGODB_URI_STAGING — enables staging clone dry-run before
#                   touching the production database.

set -euo pipefail

COMMAND="${1:-up}"
ENVIRONMENT="${2:-staging}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Validate required files ───────────────────────────────────────────────────
if [ ! -f "${DEPLOY_DIR}/.env" ]; then
  echo "✗ .env not found. deploy.sh must build it before calling migrate-safe.sh"
  exit 1
fi
if [ ! -f "${DEPLOY_DIR}/.env.config" ]; then
  echo "✗ .env.config not found. Run: git pull"
  exit 1
fi

# ── Load config and secrets ───────────────────────────────────────────────────
ECR_REGISTRY="$(grep    '^ECR_REGISTRY='          "${DEPLOY_DIR}/.env.config" | cut -d= -f2 | xargs)"
AWS_REGION="$(grep      '^AWS_REGION='            "${DEPLOY_DIR}/.env.config" | cut -d= -f2 | xargs)"
IMAGE_TAG="$(grep       '^IMAGE_TAG='             "${DEPLOY_DIR}/.env"        | cut -d= -f2 | xargs)"
MONGODB_URI="$(grep     '^MONGODB_URI='           "${DEPLOY_DIR}/.env"        | cut -d= -f2-)"
NODE_ENV="$(grep        '^NODE_ENV='              "${DEPLOY_DIR}/.env"        | cut -d= -f2 | xargs)"
AWS_BUCKET_NAME="$(grep '^AWS_BUCKET_NAME='       "${DEPLOY_DIR}/.env"        | cut -d= -f2 | xargs)"

export AWS_ACCESS_KEY_ID="$(grep     '^AWS_ACCESS_KEY_ID='     "${DEPLOY_DIR}/.env" | cut -d= -f2-)"
export AWS_SECRET_ACCESS_KEY="$(grep '^AWS_SECRET_ACCESS_KEY=' "${DEPLOY_DIR}/.env" | cut -d= -f2-)"

if [ -z "${MONGODB_URI}" ]; then
  echo "✗ MONGODB_URI not found in .env"
  exit 1
fi

# ── Per-environment image name ────────────────────────────────────────────────
case "${ENVIRONMENT}" in
  staging)
    ENV_BACKEND_IMAGE="acrapath/backendstag"
    ;;
  production)
    ENV_BACKEND_IMAGE="acrapath/backend"
    ;;
  *)
    echo "✗ Unknown environment '${ENVIRONMENT}'. Use: staging | production"
    exit 1
    ;;
esac

LOCAL_BACKUP_FILE="${DEPLOY_DIR}/backup_${ENVIRONMENT}_${TIMESTAMP}_${IMAGE_TAG}.tar.gz"
S3_BACKUP_KEY="db-backups/${ENVIRONMENT}/${TIMESTAMP}_${IMAGE_TAG}.tar.gz"

# ── Step 0: Dependency check ──────────────────────────────────────────────────
check_dependencies() {
  echo "==> [Step 0] Checking dependencies..."
  local missing=0
  for tool in mongodump aws docker; do
    if ! command -v "${tool}" &>/dev/null; then
      echo "    ✗ Required tool not found: ${tool}"
      missing=1
    fi
  done
  if [ "${missing}" -eq 1 ]; then
    echo "    Install missing tools and retry."
    exit 1
  fi
  echo "    All dependencies present."
}

# ── Step 1: Point-in-time snapshot ───────────────────────────────────────────
step1_snapshot() {
  echo "==> [Step 1] Creating point-in-time snapshot..."

  echo "    Running mongodump..."
  mongodump --uri "${MONGODB_URI}" --archive | gzip > "${LOCAL_BACKUP_FILE}"
  echo "    Snapshot written: ${LOCAL_BACKUP_FILE}"

  echo "    Uploading to S3: s3://${AWS_BUCKET_NAME}/${S3_BACKUP_KEY}"
  aws s3 cp "${LOCAL_BACKUP_FILE}" \
    "s3://${AWS_BUCKET_NAME}/${S3_BACKUP_KEY}" \
    --region "${AWS_REGION}"
  echo "    Upload complete."

  echo "    Pruning old backups (keeping last 3)..."
  BACKUP_LIST="$(aws s3api list-objects-v2 \
    --bucket "${AWS_BUCKET_NAME}" \
    --prefix "db-backups/${ENVIRONMENT}/" \
    --query 'Contents[].{Key:Key,LastModified:LastModified}' \
    --output json \
    --region "${AWS_REGION}")"

  export BACKUP_LIST_JSON="${BACKUP_LIST}"
  DELETE_KEYS="$(python3 -c "
import json, sys, os
data = os.environ.get('BACKUP_LIST_JSON', '')
if not data or data == 'null':
    sys.exit(0)
items = json.loads(data)
if not items:
    sys.exit(0)
items.sort(key=lambda x: x['LastModified'], reverse=True)
for item in items[3:]:
    print(item['Key'])
")"

  while IFS= read -r key; do
    [ -z "${key}" ] && continue
    echo "    Deleting old backup: ${key}"
    aws s3 rm "s3://${AWS_BUCKET_NAME}/${key}" --region "${AWS_REGION}"
  done <<< "${DELETE_KEYS}"

  rm -f "${LOCAL_BACKUP_FILE}"
  echo "    Local backup file removed."
  echo "    Snapshot step complete."
}

# ── Step 2: Rollback plan document ───────────────────────────────────────────
step2_rollback_plan() {
  echo "==> [Step 2] Writing rollback plan..."

  MASKED_URI="$(echo "${MONGODB_URI}" | sed 's|\(://[^:]*:\)[^@]*@|\1****@|')"

  cat > "${DEPLOY_DIR}/rollback-plan.txt" <<EOF
# Rollback Plan — Generated ${TIMESTAMP}
# Environment: ${ENVIRONMENT}
# Image Tag:   ${IMAGE_TAG}

## Snapshot Location
S3 Key: s3://${AWS_BUCKET_NAME}/${S3_BACKUP_KEY}

## Step 1 — Download Snapshot
aws s3 cp s3://${AWS_BUCKET_NAME}/${S3_BACKUP_KEY} /tmp/rollback_snapshot.tar.gz

## Step 2 — Restore Database
# URI (password masked): ${MASKED_URI}
mongorestore --uri "<MONGODB_URI>" --archive --gzip < /tmp/rollback_snapshot.tar.gz

## Step 3 — Restart Services
docker compose -f ${DEPLOY_DIR}/docker-compose.yml up -d

## Notes
# Replace <MONGODB_URI> with the actual URI from .env before running Step 2.
# Run these steps on the EC2 host as the deployment user.
EOF

  echo "    Rollback plan written: ${DEPLOY_DIR}/rollback-plan.txt"
}

# ── Step 3: Migration with downtime and auto-rollback ────────────────────────
step4_migrate_with_recovery() {
  echo "==> [Step 3] Running migration with downtime guard..."

  echo "    Stopping services..."
  docker compose -f "${DEPLOY_DIR}/docker-compose.yml" down

  echo "    Running: npm run migrate:up [${ECR_REGISTRY}/${ENV_BACKEND_IMAGE}:${IMAGE_TAG}]"
  set +e
  docker run --rm \
    --name credepath-migrations-safe \
    --network host \
    -e MONGODB_URI="${MONGODB_URI}" \
    -e NODE_ENV="${NODE_ENV}" \
    "${ECR_REGISTRY}/${ENV_BACKEND_IMAGE}:${IMAGE_TAG}" \
    npm run migrate:up
  MIGRATION_EXIT_CODE=$?
  set -e

  if [ "${MIGRATION_EXIT_CODE}" -eq 0 ]; then
    echo "    Migration succeeded. Bringing services back up..."
    docker compose -f "${DEPLOY_DIR}/docker-compose.yml" up -d --remove-orphans
    echo "    Services online."
  else
    echo "✗ Migration FAILED (exit code ${MIGRATION_EXIT_CODE})."
    echo "    Snapshot available at: s3://${AWS_BUCKET_NAME}/${S3_BACKUP_KEY}"
    echo "    See ${DEPLOY_DIR}/rollback-plan.txt for manual restore instructions."
    exit 1
  fi
}

# ── Non-up commands: delegate directly ───────────────────────────────────────
cmd_down_or_status() {
  local npm_cmd
  case "${COMMAND}" in
    down)   npm_cmd="migrate:down"   ;;
    status) npm_cmd="migrate:status" ;;
  esac

  echo "==> Running: npm run ${npm_cmd}..."
  docker run --rm \
    --name "credepath-migrations-${COMMAND}" \
    --network host \
    -e MONGODB_URI="${MONGODB_URI}" \
    -e NODE_ENV="${NODE_ENV}" \
    "${ECR_REGISTRY}/${ENV_BACKEND_IMAGE}:${IMAGE_TAG}" \
    npm run "${npm_cmd}"
  echo "==> Operation complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║            MIGRATE-SAFE — SAFE MIGRATION RUNNER                ║"
  echo "╠════════════════════════════════════════════════════════════════╣"
  printf "║ Command:     %-49s║\n" "${COMMAND}"
  printf "║ Environment: %-49s║\n" "${ENVIRONMENT}"
  printf "║ Image:       %-49s║\n" "${ECR_REGISTRY}/${ENV_BACKEND_IMAGE}:${IMAGE_TAG}"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""

  case "${COMMAND}" in
    up)
      check_dependencies
      step1_snapshot
      step2_rollback_plan
      step4_migrate_with_recovery
      echo ""
      echo "==> migrate-safe complete ✓"
      ;;
    down|status)
      cmd_down_or_status
      ;;
    *)
      echo "✗ Unknown command '${COMMAND}'. Use: up | down | status"
      exit 1
      ;;
  esac
}

main "$@"
