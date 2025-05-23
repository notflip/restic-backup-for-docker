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
    timeout 5 curl -fsS --retry 2 --max-time 3 "${HEALTHCHECK_URL}/fail" > /dev/null || echo "Healthcheck ping failed (timeout or error)"
  fi
}
trap on_failure ERR

# Check restic
if ! command -v restic >/dev/null 2>&1; then
  echo "Restic is not installed."
  exit 1
fi

echo "Using repository: $RESTIC_REPOSITORY"
restic cat config | grep -E 'repository|id|version' || echo "Warning: couldn't read repo config"

# Unlock before starting
echo "Removing stale lock (if any)..."
restic unlock

# Perform backup
echo "Starting restic backup of: $BACKUP_PATHS"
restic backup $BACKUP_PATHS

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
