#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=deploy-lib.sh
source "$(dirname "$0")/deploy-lib.sh"
[[ $# -ge 1 && $# -le 2 ]] || die 'Usage: upgrade.sh ARTIFACT_DIRECTORY [HEALTH_URL]'
HEALTH_URL=${2:-$HEALTH_URL}
host_guard
managed_service
systemctl is-active --quiet "$UNIT" || die 'Start the managed service before upgrading'
OLD=$(current_target)
trap 'recover $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage_artifact "$1"
[[ "$OLD" != "$TARGET" ]] || die 'This release is already selected'
activate
