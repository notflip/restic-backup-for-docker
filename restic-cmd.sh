#!/bin/bash
set -euo pipefail

# Load env
source restic.env

# Export required variables
export RESTIC_REPOSITORY
export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

# Pass all arguments to restic
restic "$@"
