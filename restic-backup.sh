#!/usr/bin/env bash
set -euo pipefail

# Add standard paths to ensure commands are found
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

# Set working directory explicitly (helpful for cron)
cd "$(dirname "$0")" || {
  echo "ERROR: Failed to change to script directory" >&2
  exit 1
}

# Define binaries with full paths
YQ_BIN="/snap/bin/yq"
RESTIC_BIN="$(command -v restic || echo "/snap/bin/restic")"

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') $1"
}

log "Starting backup script..."
log "Working directory: $(pwd)"

# ── Configuration ───────────────────────────────────────────────────────────
CONFIG="./config.yml"

if [[ ! -f "$CONFIG" ]]; then
  log "ERROR: Configuration file not found: $CONFIG"
  exit 1
fi

log "Reading configuration from $CONFIG"

log "Reading Restic repository..."
RESTIC_REPOSITORY=$($YQ_BIN '.restic.repository' "$CONFIG")
export RESTIC_REPOSITORY
log "Repository: $RESTIC_REPOSITORY"

log "Reading credentials and settings..."
export RESTIC_PASSWORD=$($YQ_BIN '.restic.password' "$CONFIG")
export AWS_ACCESS_KEY_ID=$($YQ_BIN '.restic.aws.access_key_id' "$CONFIG")
export AWS_SECRET_ACCESS_KEY=$($YQ_BIN '.restic.aws.secret_access_key' "$CONFIG")
export AWS_DEFAULT_REGION=$($YQ_BIN '.restic.aws.region' "$CONFIG" || echo "us-east-1")
export RESTIC_LOCK_TIMEOUT=$($YQ_BIN '.restic.lock_timeout' "$CONFIG" || echo "30")

# Lower memory usage for pruning
export GOGC=20

VOL_BASE=$($YQ_BIN '.restic.volume_base_path' "$CONFIG")
KEEP_DAILY=$($YQ_BIN '.retention.keep_daily' "$CONFIG" || echo "7")
KEEP_WEEKLY=$($YQ_BIN '.retention.keep_weekly' "$CONFIG" || echo "4")
KEEP_MONTHLY=$($YQ_BIN '.retention.keep_monthly' "$CONFIG" || echo "12")

log "Reading healthchecks URL..."
HC_URL=$($YQ_BIN '.healthchecks_url' "$CONFIG")
log "Raw HC_URL: '$HC_URL'"

if [[ -z "$HC_URL" ]]; then
  log "WARNING: No healthchecks URL found in config, continuing without healthchecks"
  HC_URL=""
else
  HC_URL="${HC_URL%/}"
  log "Processed HC_URL: '$HC_URL'"

  if [[ ! "$HC_URL" =~ ^https?:// ]]; then
    log "ERROR: Healthchecks URL doesn't start with http:// or https://"
    exit 1
  fi
fi

log "Reading project list..."
mapfile -t PROJECTS < <($YQ_BIN '.projects | keys | .[]' "$CONFIG")
log "Found projects: ${PROJECTS[*]}"

# ── Healthchecks ping helper ─────────────────────────────────────────────────
ping_health() {
  [[ -z "$HC_URL" ]] && return 0

  local status="$1"
  local url

  if [[ "$status" == "start" ]]; then
    url="$HC_URL/start"
  elif [[ "$status" == "fail" ]]; then
    url="$HC_URL/fail"
  elif [[ "$status" == "success" ]]; then
    url="$HC_URL"
  else
    url="$HC_URL/$status"
  fi

  log "Pinging healthcheck: $status"
  curl -fsS --max-time 10 "$url" >/dev/null 2>&1 || log "WARNING: Failed to ping healthcheck"
}

# ── Start backup ────────────────────────────────────────────────────────────
log "==== Starting backup ===="

if [[ -n "$HC_URL" ]]; then
  ping_health start || log "Healthcheck start ping failed, continuing anyway"
fi

log "Looking for restic binary..."
if [[ ! -x "$RESTIC_BIN" ]]; then
  log "ERROR: restic command not found at $RESTIC_BIN"
  [[ -n "$HC_URL" ]] && ping_health fail
  exit 1
fi
log "Found restic at: $RESTIC_BIN"

log "Checking for and removing any stale locks"
"$RESTIC_BIN" unlock || log "WARNING: Failed to clear locks, but will continue"

exit_code=0

# ── Backup loop ────────────────────────────────────────────────────────────
for project in "${PROJECTS[@]}"; do
  log "-- Project: $project"

  log "Reading volumes for $project..."
  mapfile -t vols < <($YQ_BIN ".projects.[\"$project\"].volumes[]" "$CONFIG" 2>/dev/null || echo "")

  log "Found volumes for $project: ${vols[*]}"

  if [[ ${#vols[@]} -eq 0 ]]; then
    log "   !! No volumes defined for $project"
    continue
  fi

  paths=()
  for v in "${vols[@]}"; do
    dir="$VOL_BASE/$v/_data"
    if [[ -d "$dir" ]]; then
      paths+=("$dir")
      log "Found valid path: $dir"
    else
      log "   !! Missing volume path: $dir"
    fi
  done

  if [[ ${#paths[@]} -eq 0 ]]; then
    log "   !! No valid volumes for $project, skipping"
    continue
  fi

  log "Starting backup for $project with paths: ${paths[*]}"
  if ! "$RESTIC_BIN" backup "${paths[@]}" --tag "$project"; then
    log "   !! Backup failed for $project"
    exit_code=1
    continue
  fi

  log "Unlocking repository after backup for $project"
  "$RESTIC_BIN" unlock --remove-all || log "WARNING: Failed to clear locks"

  sleep 2

  log "Applying retention policy for $project"
  # Split forget and prune operations to reduce memory usage
  if ! "$RESTIC_BIN" forget \
        --tag "$project" \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY"; then
    log "   !! Forget operation failed for $project"
    exit_code=1
  else
    log "Forget operation completed successfully for $project"
    
    # Now run prune as a separate operation
    log "Starting prune operation for $project"
    if ! "$RESTIC_BIN" prune; then
      log "   !! Prune failed for $project"
      exit_code=1
    else
      log "Prune completed successfully for $project"
    fi
  fi

  log "-- Completed $project"
done

# ── Finish ────────────────────────────────────────────────────────────
log "==== Backup finished with status: $([ $exit_code -eq 0 ] && echo 'SUCCESS' || echo 'FAILED') ===="

if [[ -n "$HC_URL" ]]; then
  if [[ $exit_code -eq 0 ]]; then
    ping_health success || log "Final healthcheck ping failed"
  else
    ping_health fail || log "Final healthcheck ping failed"
  fi
fi

log "Backup script completed with exit code: $exit_code"
exit $exit_code