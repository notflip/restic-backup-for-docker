set -euo pipefail

# Detect server identifier (hostname or custom identifier)
SERVER_ID=$(hostname -s)

# Enhanced locking mechanism
LOCKFILE="/tmp/restic-backup-${SERVER_ID}.lock"
LOCKFD=99

# POSIX compliant lock function
lock() {
    # Acquire lock
    eval "exec $LOCKFD>\"$LOCKFILE\""
    if ! flock -n "$LOCKFD"; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') Another backup process is already running. Exiting."
        exit 1
    fi
}

# Release lock
unlock() {
    if [[ -f "$LOCKFILE" ]]; then
        flock -u "$LOCKFD"
        rm -f "$LOCKFILE"
    fi
}

# Trap to ensure lock is released even if script fails
trap 'unlock' EXIT INT TERM

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
  echo "$(date +'%Y-%m-%d %H:%M:%S') [$SERVER_ID] $1"
}

# Memory management enhancements
export GOGC=20                # Aggressive garbage collection
export GOMAXPROCS=1           # Limit CPU usage
export RESTIC_CACHE_DIR="/tmp/restic-cache-${SERVER_ID}"  # Dedicated cache directory
export GODEBUG=madvdontneed=1 # Improve memory release patterns

# Create and clean cache directory
mkdir -p "$RESTIC_CACHE_DIR"
find "$RESTIC_CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null || true

# Acquire the lock
lock

log "Starting backup script..."
log "Working directory: $(pwd)"
log "Server Identifier: $SERVER_ID"
log "Memory optimization: GOGC=$GOGC, GOMAXPROCS=$GOMAXPROCS"

# ── Configuration ───────────────────────────────────────────────────────────
CONFIG="./config.yml"

if [[ ! -f "$CONFIG" ]]; then
  log "ERROR: Configuration file not found: $CONFIG"
  exit 1
fi

log "Reading configuration from $CONFIG"

# Generate dynamic repository path
log "Reading Restic repository..."
RESTIC_REPOSITORY=$($YQ_BIN '.restic.repository' "$CONFIG" | sed "s/SERVER_IDENTIFIER/$SERVER_ID/g")
export RESTIC_REPOSITORY
log "Repository: $RESTIC_REPOSITORY"

# Dynamically update AWS credentials
log "Reading credentials and settings..."
RESTIC_PASSWORD=$($YQ_BIN '.restic.password' "$CONFIG")
AWS_ACCESS_KEY_ID=$($YQ_BIN '.restic.aws.access_key_id' "$CONFIG")
AWS_SECRET_ACCESS_KEY=$($YQ_BIN '.restic.aws.secret_access_key' "$CONFIG")
AWS_DEFAULT_REGION=$($YQ_BIN '.restic.aws.region' "$CONFIG" || echo "us-east-1")
RESTIC_LOCK_TIMEOUT=$($YQ_BIN '.restic.lock_timeout' "$CONFIG" || echo "30")

# Export credentials securely
export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION
export RESTIC_LOCK_TIMEOUT

# Read configuration values
VOL_BASE=$($YQ_BIN '.restic.volume_base_path' "$CONFIG")
KEEP_DAILY=$($YQ_BIN '.retention.keep_daily' "$CONFIG" || echo "7")
KEEP_WEEKLY=$($YQ_BIN '.retention.keep_weekly' "$CONFIG" || echo "4")
KEEP_MONTHLY=$($YQ_BIN '.retention.keep_monthly' "$CONFIG" || echo "12")

# Healthchecks setup
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

# Healthchecks ping helper
ping_health() {
  [[ -z "$HC_URL" ]] && return 0

  local status="$1"
  local url

  case "$status" in
    "start") url="$HC_URL/start" ;;
    "fail") url="$HC_URL/fail" ;;
    "success") url="$HC_URL" ;;
    *) url="$HC_URL/$status" ;;
  esac

  log "Pinging healthcheck: $status"
  curl -fsS --max-time 10 "$url" >/dev/null 2>&1 || log "WARNING: Failed to ping healthcheck"
}

# Start backup process
log "==== Starting backup ===="

if [[ -n "$HC_URL" ]]; then
  ping_health start || log "Healthcheck start ping failed, continuing anyway"
fi

# Verify restic binary
log "Looking for restic binary..."
if [[ ! -x "$RESTIC_BIN" ]]; then
  log "ERROR: restic command not found at $RESTIC_BIN"
  ping_health fail
  exit 1
fi
log "Found restic at: $RESTIC_BIN"

# Initialize repository if it doesn't exist
if ! "$RESTIC_BIN" snapshots &>/dev/null; then
  log "Initializing new repository at $RESTIC_REPOSITORY"
  "$RESTIC_BIN" init || {
    log "ERROR: Failed to initialize repository"
    ping_health fail
    exit 1
  }
fi

# Remove stale locks
log "Checking for and removing any stale locks"
"$RESTIC_BIN" unlock || log "WARNING: Failed to clear locks, but will continue"

exit_code=0

# Read projects to backup
log "Reading project list..."
mapfile -t PROJECTS < <($YQ_BIN '.projects | keys | .[]' "$CONFIG")
log "Found projects: ${PROJECTS[*]}"

# Backup loop
for project in "${PROJECTS[@]}"; do
  log "-- Project: $project"

  # Read volumes for the project
  log "Reading volumes for $project..."
  mapfile -t vols < <($YQ_BIN ".projects.[\"$project\"].volumes[]" "$CONFIG" 2>/dev/null || echo "")

  log "Found volumes for $project: ${vols[*]}"

  if [[ ${#vols[@]} -eq 0 ]]; then
    log "   !! No volumes defined for $project"
    continue
  fi

  # Validate and collect volume paths
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

  # Clear system caches to free up memory before backup
  sync
  log "Freeing system caches before backup"
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi

  # Perform backup with timeout and memory constraints
  log "Starting backup for $project with paths: ${paths[*]}"
  if ! timeout -k 180 3600 "$RESTIC_BIN" backup "${paths[@]}" \
       --tag "$project" \
       --tag "$SERVER_ID" \
       --limit-upload 1024 \
       --one-file-system; then
    log "   !! Backup failed for $project"
    exit_code=1
    
    # Ensure restic process is completely stopped
    pkill -f "$RESTIC_BIN" || true
    sleep 5
    
    continue
  fi

  # Clear cache after backup to free up memory
  rm -rf "$RESTIC_CACHE_DIR"/* 2>/dev/null || true
  mkdir -p "$RESTIC_CACHE_DIR"

  # Unlock repository
  log "Unlocking repository after backup for $project"
  "$RESTIC_BIN" unlock --remove-all || log "WARNING: Failed to clear locks"

  sleep 2

  # Apply retention policy with timeout
  log "Applying retention policy for $project"
  if ! timeout -k 120 1800 "$RESTIC_BIN" forget \
        --tag "$project" \
        --tag "$SERVER_ID" \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --prune; then
    log "   !! Retention policy failed for $project"
    exit_code=1
  else
    log "Retention policy applied successfully for $project"
  fi

  log "-- Completed $project"
  
  # Release memory between project backups
  sync
  sleep 5
done

# Finalize backup process
log "==== Backup finished with status: $([ $exit_code -eq 0 ] && echo 'SUCCESS' || echo 'FAILED') ===="

# Ping healthchecks
if [[ -n "$HC_URL" ]]; then
  if [[ $exit_code -eq 0 ]]; then
    ping_health success || log "Final healthcheck ping failed"
  else
    ping_health fail || log "Final healthcheck ping failed"
  fi
fi

log "Backup script completed with exit code: $exit_code"
exit $exit_code