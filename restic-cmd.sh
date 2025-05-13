#!/usr/bin/env bash
set -euo pipefail

# Get server identifier (hostname)
SERVER_ID=$(hostname -s)

# Configuration file
CONFIG="./config.yml"

# Ensure config file exists
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG"
  exit 1
fi

# Check for required binaries
if [[ ! -x "/snap/bin/yq" ]]; then
  echo "ERROR: yq command not found"
  exit 1
fi

RESTIC_BIN="$(command -v restic || echo "/snap/bin/restic")"
if [[ ! -x "$RESTIC_BIN" ]]; then
  echo "ERROR: restic command not found"
  exit 1
fi

# Export required environment variables
RESTIC_REPOSITORY=$(/snap/bin/yq '.restic.repository' "$CONFIG" | sed "s/SERVER_IDENTIFIER/$SERVER_ID/g")
export RESTIC_REPOSITORY
export RESTIC_PASSWORD=$(/snap/bin/yq '.restic.password' "$CONFIG")
export AWS_ACCESS_KEY_ID=$(/snap/bin/yq '.restic.aws.access_key_id' "$CONFIG")
export AWS_SECRET_ACCESS_KEY=$(/snap/bin/yq '.restic.aws.secret_access_key' "$CONFIG")
export AWS_DEFAULT_REGION=$(/snap/bin/yq '.restic.aws.region' "$CONFIG" || echo "us-east-1")

echo "Using repository: $RESTIC_REPOSITORY"

# Run restic with the command passed as arguments
"$RESTIC_BIN" "$@"