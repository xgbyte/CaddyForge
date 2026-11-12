#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=deploy-lib.sh
source "$(dirname "$0")/deploy-lib.sh"
[[ $# -le 1 ]] || die 'Usage: rollback.sh [HEALTH_URL]'
HEALTH_URL=${1:-$HEALTH_URL}
host_guard
managed_service
systemctl is-active --quiet "$UNIT" || die 'Start the managed service before rolling back'
OLD=$(current_target)
[[ -L "$BASE/previous" ]] || die 'No previous release'
TARGET=$(readlink -f "$BASE/previous")
[[ "$(dirname "$TARGET")" == "$BASE/releases" && "$TARGET" != "$OLD" ]] || die 'Invalid previous release'
verify_artifact "$TARGET"
trap 'recover $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
activate
