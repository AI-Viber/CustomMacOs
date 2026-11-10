#!/bin/bash
# Refreshes Sources/Monitor from the MenuPulse project in the folder next to this one.
#   Tools/sync-monitor.sh [path-to-MenuPulse]
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="${1:-../MenuPulse}/Sources/MenuPulse/Monitor"

if [[ ! -d "$SOURCE" ]]; then
  echo "MenuPulse monitor sources not found at: $SOURCE"
  exit 1
fi

rsync -a --delete --exclude '.DS_Store' "$SOURCE/" Sources/Monitor/
echo "Sources/Monitor now matches $SOURCE"
