#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --install-xcaddy ) ]] || die 'Usage: bootstrap.sh [--install-xcaddy]'
load_versions "$CF_ROOT/config/versions.conf"
check_go
for cmd in git curl tar awk; do need "$cmd"; done
if [[ "${1:-}" == --install-xcaddy ]]; then
    mkdir -p "$CF_ROOT/.tools"
    GOTOOLCHAIN=local GOBIN="$CF_ROOT/.tools" go install "github.com/caddyserver/xcaddy/cmd/xcaddy@$XCADDY_VERSION"
fi
[[ -x "$CF_ROOT/.tools/xcaddy" ]] || die 'Run bootstrap.sh --install-xcaddy to install the pinned xcaddy locally'
info=$(go version -m "$CF_ROOT/.tools/xcaddy")
printf '%s\n' "$info" | awk -v v="$XCADDY_VERSION" '$1=="mod" && $2=="github.com/caddyserver/xcaddy" && $3==v {ok=1} END {exit !ok}' || die 'xcaddy pin mismatch'
printf 'Build prerequisites ready. No system packages or services changed.\n'
