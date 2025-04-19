#!/usr/bin/env bash
set -euo pipefail

# Configuration file
CONFIG="./config.yml"

# Ensure config file exists
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG"
  exit 1
fi

# Export required environment variables
export RESTIC_REPOSITORY=$(yq '.restic.repository' "$CONFIG")
export RESTIC_PASSWORD=$(yq '.restic.password' "$CONFIG")
export AWS_ACCESS_KEY_ID=$(yq '.restic.aws.access_key_id' "$CONFIG")
export AWS_SECRET_ACCESS_KEY=$(yq '.restic.aws.secret_access_key' "$CONFIG")

# Run restic with all provided arguments
restic "$@"