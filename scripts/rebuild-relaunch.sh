#!/usr/bin/env bash
set -euo pipefail
# Kill, rebuild, relaunch
pgrep -f ClaudeDashboard | xargs kill -9 2>/dev/null || true
sleep 1
bash "$(dirname "$0")/install.sh"
open /Applications/ClaudeDashboard.app
