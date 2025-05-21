#!/bin/bash
set -euo pipefail

# Load environment
ENV_FILE="restic.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE file."
  exit 1
fi
source "$ENV_FILE"

# Export credentials for Restic
export RESTIC_REPOSITORY
export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

# On failure, ping /fail
function on_failure {
  echo "Backup failed."
  if [ -n "${HEALTHCHECK_URL:-}" ]; then
    curl -fsS --retry 3 "${HEALTHCHECK_URL}/fail" > /dev/null || true
  fi
}
trap on_failure ERR

# Check restic
if ! command -v restic >/dev/null 2>&1; then
  echo "Restic is not installed."
  exit 1
fi

# Perform backup
echo "Starting restic backup of: $BACKUP_PATHS"
restic backup $BACKUP_PATHS

echo "Removing stale lock (if any)..."
restic unlock

echo "Forgetting old snapshots (keep 7 daily, 4 weekly)..."
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --prune

# Ping healthchecks success
if [ -n "${HEALTHCHECK_URL:-}" ]; then
  curl -fsS --retry 3 "$HEALTHCHECK_URL" > /dev/null || true
fi

echo "Backup and cleanup complete."