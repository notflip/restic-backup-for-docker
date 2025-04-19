#!/usr/bin/env bash
set -euo pipefail

# Add console output from the start
echo "Starting backup script..."

# ── Configuration ───────────────────────────────────────────────────────────
CONFIG="./config.yml"

# Check if config file exists
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG"
  exit 1
fi

echo "Reading configuration from $CONFIG"

# Load settings with echo for debugging
echo "Reading Restic repository..."
RESTIC_REPOSITORY=$(yq '.restic.repository' "$CONFIG")
export RESTIC_REPOSITORY
echo "Repository: $RESTIC_REPOSITORY"

echo "Reading credentials and settings..."
export RESTIC_PASSWORD=$(yq '.restic.password' "$CONFIG")
export AWS_ACCESS_KEY_ID=$(yq '.restic.aws.access_key_id' "$CONFIG")
export AWS_SECRET_ACCESS_KEY=$(yq '.restic.aws.secret_access_key' "$CONFIG")
export AWS_DEFAULT_REGION=$(yq '.restic.aws.region' "$CONFIG" || echo "us-east-1")
export RESTIC_LOCK_TIMEOUT=$(yq '.restic.lock_timeout' "$CONFIG" || echo "30")

# Directories and retention
LOG_DIR_BASE=$(yq '.restic.log_dir' "$CONFIG" || echo "./logs")
VOL_BASE=$(yq '.restic.volume_base_path' "$CONFIG")
KEEP_DAILY=$(yq '.retention.keep_daily' "$CONFIG" || echo "7")
KEEP_WEEKLY=$(yq '.retention.keep_weekly' "$CONFIG" || echo "4")
KEEP_MONTHLY=$(yq '.retention.keep_monthly' "$CONFIG" || echo "12")

# Get healthchecks URL
echo "Reading healthchecks URL..."
HC_URL=$(yq '.healthchecks_url' "$CONFIG")
echo "Raw HC_URL: '$HC_URL'"

# Safety check and cleanup for URL
if [[ -z "$HC_URL" ]]; then
  echo "WARNING: No healthchecks URL found in config, continuing without healthchecks"
  HC_URL=""
else
  # Remove trailing slashes and check format
  HC_URL="${HC_URL%/}"
  echo "Processed HC_URL: '$HC_URL'"
  
  # Basic URL validation
  if [[ ! "$HC_URL" =~ ^https?:// ]]; then
    echo "ERROR: Healthchecks URL doesn't start with http:// or https://"
    exit 1
  fi
fi

# Read project names
echo "Reading project list..."
mapfile -t PROJECTS < <(yq '.projects | keys | .[]' "$CONFIG")
echo "Found projects: ${PROJECTS[*]}"

# ── Prepare monthly log file ─────────────────────────────────────────────────
MONTH=$(date +'%Y-%m')
LOG_DIR="$LOG_DIR_BASE/$MONTH"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup.log"
echo "Logging to: $LOG_FILE"

# ── Logging helper ─────────────────────────────────────────────────────────
log() { 
  local msg="$(timestamp) $1"
  echo "$msg" >> "$LOG_FILE"
  echo "$msg" # Also output to console
}

timestamp() { date +'%Y-%m-%d %H:%M:%S'; }

# ── Healthchecks ping helper ───────────────────────────────────────────────
ping_health() {
  [[ -z "$HC_URL" ]] && return 0
  
  local status="$1"
  local url
  
  # Construct URLs manually without string interpolation
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
  
  # Simplified curl command without verbose output
  curl -fsS "$url" >> "$LOG_FILE" 2>&1
  return 0
}

# ── Start healthchecks ping ─────────────────────────────────────────────────
log "==== Starting backup ===="

# Only ping if we have a valid URL
if [[ -n "$HC_URL" ]]; then
  ping_health start || log "Healthcheck start ping failed, continuing anyway"
fi

# Check for restic binary
echo "Looking for restic binary..."
RESTIC_BIN=$(command -v restic || echo "")
if [[ -z "$RESTIC_BIN" ]]; then
  log "ERROR: restic command not found"
  [[ -n "$HC_URL" ]] && ping_health fail
  exit 1
fi
echo "Found restic at: $RESTIC_BIN"

# Clear all stale locks at the beginning
log "Checking for and removing any stale locks"
"$RESTIC_BIN" unlock >> "$LOG_FILE" 2>&1 || log "WARNING: Failed to clear locks, but will continue"

exit_code=0

# ── Backup loop ───────────────────────────────────────────────────────────────
for project in "${PROJECTS[@]}"; do
  log "-- Project: $project"
  
  # Read volumes for project
  echo "Reading volumes for $project..."
  # Explicit YQ v4 syntax
  mapfile -t vols < <(yq ".projects.[\"$project\"].volumes[]" "$CONFIG" 2>/dev/null || echo "")
  
  echo "Found volumes for $project: ${vols[*]}"
  
  # Check if we got any volumes
  if [[ ${#vols[@]} -eq 0 ]]; then
    log "   !! No volumes defined for $project"
    continue
  fi

  paths=()
  for v in "${vols[@]}"; do
    dir="$VOL_BASE/$v/_data"
    if [[ -d "$dir" ]]; then
      paths+=("$dir")
      echo "Found valid path: $dir"
    else
      log "   !! Missing volume path: $dir"
    fi
  done

  if [[ ${#paths[@]} -eq 0 ]]; then
    log "   !! No valid volumes for $project, skipping"
    continue
  fi

  # Run restic backup
  log "Starting backup for $project with paths: ${paths[*]}"
  if ! "$RESTIC_BIN" backup "${paths[@]}" --tag "$project" >> "$LOG_FILE" 2>&1; then
    log "   !! Backup failed for $project"
    exit_code=1
    continue
  fi

  # Remove stale locks
  log "Unlocking repository after backup for $project"
  "$RESTIC_BIN" unlock --remove-all >> "$LOG_FILE" 2>&1 || log "WARNING: Failed to clear locks"
  
  # Wait a moment to ensure locks are released
  sleep 2

  # Apply retention policy
  log "Applying retention policy for $project"
  if ! "$RESTIC_BIN" forget \
        --tag "$project" \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --prune >> "$LOG_FILE" 2>&1; then
    log "   !! Prune failed for $project"
    exit_code=1
  else
    log "Retention policy applied successfully for $project"
  fi

  log "-- Completed $project"
done

# ── Finish ───────────────────────────────────────────────────────────────────
log "==== Backup finished with status: $([ $exit_code -eq 0 ] && echo 'SUCCESS' || echo 'FAILED') ===="

if [[ -n "$HC_URL" ]]; then
  if [[ $exit_code -eq 0 ]]; then
    ping_health success || log "Final healthcheck ping failed"
  else
    ping_health fail || log "Final healthcheck ping failed"
  fi
fi

echo "Backup script completed with exit code: $exit_code"
exit $exit_code