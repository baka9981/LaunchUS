#!/bin/bash
# Rebuild, quit any running copy, and launch LaunchUS.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "${1:-release}"
pkill -x LaunchUS 2>/dev/null && sleep 0.5 || true
open build/LaunchUS.app
