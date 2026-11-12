#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[[ $# -ge 1 && $# -le 2 ]] || die 'Usage: verify.sh ARTIFACT_DIRECTORY [CADDYFILE]'
verify_artifact "$1"
"$1/caddy" validate --adapter caddyfile --config "${2:-$CF_ROOT/examples/Caddyfile}"
printf 'Artifact verified.\n'
