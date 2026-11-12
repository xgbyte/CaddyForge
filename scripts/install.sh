#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=deploy-lib.sh
source "$(dirname "$0")/deploy-lib.sh"
[[ $# -ge 1 && $# -le 2 ]] || die 'Usage: install.sh ARTIFACT_DIRECTORY [HEALTH_URL]'
HEALTH_URL=${2:-$HEALTH_URL}
host_guard
[[ ! -e "$BASE/current" && ! -L "$BASE/current" ]] || die 'Already installed; use upgrade.sh'
for unit in caddy.service caddy-api.service; do
    if systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit"; then
        die "Existing $unit is active/enabled. Plan migration explicitly before installing CaddyForge"
    fi
done
[[ ! -L "$UNIT_FILE" ]] || die 'Refusing symlinked service file'
[[ ! -e "$UNIT_FILE" ]] || cmp -s "$CF_ROOT/config/caddyforge.service" "$UNIT_FILE" || die 'Existing unit differs; refusing to overwrite'
if getent passwd caddyforge >/dev/null; then
    [[ "$(getent passwd caddyforge | cut -d: -f6)" == /var/lib/caddyforge ]] || die 'Existing user has an unexpected home'
    [[ "$(id -u caddyforge)" != 0 ]] || die 'Service user cannot be root'
else
    useradd --system --user-group --home-dir /var/lib/caddyforge --shell /usr/sbin/nologin caddyforge
fi
install -d -o root -g root -m 0755 "$BASE" "$BASE/releases"
install -d -o root -g caddyforge -m 0750 "$ETC"
[[ -d /var/lib/caddyforge ]] || install -d -o caddyforge -g caddyforge -m 0750 /var/lib/caddyforge
[[ -e "$ETC/Caddyfile" ]] || install -o root -g caddyforge -m 0640 "$CF_ROOT/examples/Caddyfile" "$ETC/Caddyfile"
[[ -e "$ETC/caddy.env" ]] || install -o root -g root -m 0600 "$CF_ROOT/config/caddy.env.example" "$ETC/caddy.env"
trap 'recover $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage_artifact "$1"
install -o root -g root -m 0644 "$CF_ROOT/config/caddyforge.service" "$UNIT_FILE"
systemctl daemon-reload
managed_service
activate
# First install starts the service; boot enablement is an explicit documented step.
