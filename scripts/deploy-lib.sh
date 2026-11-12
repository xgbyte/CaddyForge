#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BASE=/opt/caddyforge
ETC=/etc/caddyforge
UNIT=caddyforge.service
UNIT_FILE=/etc/systemd/system/caddyforge.service
HEALTH_URL=http://127.0.0.1:8080/healthz
host_guard() {
    [[ $EUID -eq 0 ]] || die 'Deployment requires root on the target Debian 13 host'
    [[ -f /etc/os-release ]] || die 'Missing /etc/os-release'
    # OS-owned file; unlike user manifests this is trusted system metadata.
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" == 13 ]] || die 'Deployment supports Debian 13 only'
    for cmd in systemctl systemd-run flock curl readlink install getent useradd stat; do need "$cmd"; done
    exec 9>/run/lock/caddyforge.lock
    flock -n 9 || die 'Another deployment is running'
    local path
    for path in "$BASE" "$BASE/releases" "$ETC" /var/lib/caddyforge; do
        [[ ! -L "$path" ]] || die "Refusing symlinked managed directory: $path"
        if [[ -e "$path" ]]; then
            [[ -d "$path" ]] || die "Not a directory: $path"
            if [[ "$path" == /var/lib/caddyforge ]]; then
                [[ "$(stat -c %U "$path")" == caddyforge ]] || die "Unexpected data owner: $path"
            else
                [[ "$(stat -c %u "$path")" == 0 ]] || die "Unsafe directory owner: $path"
            fi
            [[ $(stat -c %a "$path") =~ ^[0-7]*[0145][0145]$ ]] || die "Group/world writable directory: $path"
        fi
    done
}
managed_service() {
    [[ -f "$ETC/caddy.env" && ! -L "$ETC/caddy.env" && "$(stat -c %u "$ETC/caddy.env")" == 0 && "$(stat -c %a "$ETC/caddy.env")" == 600 ]] || die 'Environment file must be root-owned, regular, mode 0600'
    [[ -f "$ETC/Caddyfile" && ! -L "$ETC/Caddyfile" && "$(stat -c %u "$ETC/Caddyfile")" == 0 ]] || die 'Caddyfile must be a root-owned regular file'
    [[ $(stat -c %a "$ETC/Caddyfile") =~ ^[0-7]*[0145][0145]$ ]] || die 'Caddyfile cannot be group/world writable'
    [[ -f "$UNIT_FILE" && ! -L "$UNIT_FILE" ]] || die 'Managed service is not installed'
    cmp -s "$CF_ROOT/config/caddyforge.service" "$UNIT_FILE" || die 'Service differs from this repository; review it before deployment'
    [[ -z "$(systemctl show "$UNIT" -p DropInPaths --value)" ]] || die 'Review/remove service drop-ins before using deployment scripts'
    [[ "$(systemctl show "$UNIT" -p FragmentPath --value)" == "$UNIT_FILE" ]] || die 'Unexpected unit path'
}
current_target() {
    local target
    [[ -L "$BASE/current" ]] || die 'No managed current release'
    target=$(readlink -f "$BASE/current")
    [[ "$target" == "$BASE/releases/"* && -d "$target" && "$(dirname "$target")" == "$BASE/releases" ]] || die 'Current release is outside managed releases'
    printf '%s\n' "$target"
}
validate_candidate() {
    # Same user, environment, working directory and filesystem restrictions as service.
    systemd-run --quiet --wait --pipe --collect --service-type=exec \
        -p User=caddyforge -p Group=caddyforge -p RuntimeMaxSec=120 -p TimeoutStartSec=120 \
        -p EnvironmentFile="$ETC/caddy.env" -p WorkingDirectory="$ETC" \
        -p NoNewPrivileges=true -p PrivateTmp=true -p ProtectSystem=strict -p ProtectHome=true \
        -p ReadWritePaths=/var/lib/caddyforge -p UMask=0027 \
        --setenv=HOME=/var/lib/caddyforge --setenv=XDG_DATA_HOME=/var/lib/caddyforge \
        --setenv=XDG_CONFIG_HOME=/var/lib/caddyforge \
        "$1/caddy" validate --adapter caddyfile --config "$ETC/Caddyfile"
}
atomic_link() {
    local temp
    temp=$(mktemp -d "$BASE/.switch.XXXXXX") || return 1
    if ln -s "$1" "$temp/link" && mv -Tf "$temp/link" "$2"; then
        rmdir "$temp" || true
        return 0
    fi
    rm -f "$temp/link"
    rmdir "$temp" || true
    return 1
}
health() {
    local target=$1 attempt pid
    for ((attempt=0;attempt<15;attempt++)); do
        if systemctl is-active --quiet "$UNIT"; then
            pid=$(systemctl show "$UNIT" -p MainPID --value)
            if [[ "$pid" =~ ^[1-9][0-9]*$ && "$(readlink -f "/proc/$pid/exe")" == "$target/caddy" ]] &&
                curl --noproxy '*' --fail --silent --show-error --max-time 2 "$HEALTH_URL" >/dev/null; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}
stage_artifact() {
    local artifact=$1 release_id name
    verify_artifact "$artifact"
    # Ensure this is a native Linux binary, without requiring Go on the target.
    [[ "$(od -An -tx1 -N4 "$artifact/caddy" | tr -d ' \n')" == 7f454c46 ]] || die 'Target deployment requires a Linux ELF binary'
    release_id=$(sha256 "$artifact/SHA256SUMS")
    TARGET="$BASE/releases/$release_id"
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        verify_artifact "$TARGET"
        [[ "$(sha256 "$TARGET/SHA256SUMS")" == "$release_id" ]] || die 'Release identity mismatch'
        return
    fi
    STAGE=$(mktemp -d "$BASE/releases/.staging.XXXXXX")
    for name in caddy versions.conf plugins.conf build-info.txt modules.txt SHA256SUMS; do
        install -o root -g root -m 0644 "$artifact/$name" "$STAGE/$name"
    done
    chmod 0755 "$STAGE" "$STAGE/caddy"
    verify_artifact "$STAGE"
    mv -T "$STAGE" "$TARGET"
    STAGE=
}
# Trap state is global because signals may arrive between shell commands.
OLD='' TARGET='' STAGE='' SWITCHING=0
recover() {
    local status=$1
    trap - EXIT INT TERM
    [[ -z "$STAGE" ]] || rm -rf "$STAGE"
    if [[ "$SWITCHING" == 1 ]]; then
        printf 'Activation failed; restoring previous binary selection.\n' >&2
        if [[ -n "$OLD" ]]; then
            if atomic_link "$OLD" "$BASE/current" && systemctl restart "$UNIT" && health "$OLD"; then
                printf 'Previous release restored and healthy.\n' >&2
            else
                printf 'RECOVERY FAILED. Inspect journalctl -u caddyforge and the current link.\n' >&2
            fi
        else
            systemctl stop "$UNIT" || true
            rm -f "$BASE/current"
        fi
    fi
    exit "$status"
}
activate() {
    validate_candidate "$TARGET"
    # Set before mutation so a TERM immediately after rename still triggers recovery.
    SWITCHING=1
    atomic_link "$TARGET" "$BASE/current"
    systemctl restart "$UNIT"
    health "$TARGET" || die 'New release failed its health check'
    if [[ -n "$OLD" && "$OLD" != "$TARGET" ]]; then
        atomic_link "$OLD" "$BASE/previous"
    fi
    SWITCHING=0
    printf 'Activated %s\n' "$TARGET"
}
