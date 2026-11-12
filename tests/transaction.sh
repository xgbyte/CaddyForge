#!/usr/bin/env bash
# Only called by run.sh. All service operations and paths are isolated doubles.
set -euo pipefail
# shellcheck source=../scripts/deploy-lib.sh
source "$(dirname "$0")/../scripts/deploy-lib.sh"
BASE=$1
scenario=$2
OLD="$BASE/releases/old"
TARGET="$BASE/releases/new"
[[ "$scenario" != first ]] || OLD=
validate_candidate() { [[ "$scenario" != validation ]]; }
atomic_link() {
    # Python os.replace supplies the same atomic rename semantics on macOS/Linux.
    python3 - "$1" "$2" <<'PYCODE'
import os,sys
os.symlink(sys.argv[1],sys.argv[2]+'.tmp')
os.replace(sys.argv[2]+'.tmp',sys.argv[2])
PYCODE
    if [[ "$scenario" == signal && "$1" == "$TARGET" ]]; then kill -TERM $$; fi
}
systemctl() {
    printf '%s\n' "$*" >> "$BASE/events"
    if [[ "$scenario" == recovery-fail ]]; then return 1; fi
    if [[ "$scenario" == restart && "$1" == restart && "$(readlink "$BASE/current")" == "$TARGET" ]]; then return 1; fi
    return 0
}
health() {
    [[ "$1" == "$OLD" || "$scenario" == success || "$scenario" == signal ]]
}
trap 'recover $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
activate
