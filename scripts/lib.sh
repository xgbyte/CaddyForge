#!/usr/bin/env bash
# Shared functions; manifests are parsed as data, never sourced.
set -euo pipefail
# Used by scripts that source this library.
# shellcheck disable=SC2034
CF_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf 'CaddyForge: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
load_versions() {
    local key value seen=" "
    CADDY_VERSION='' XCADDY_VERSION='' GO_MIN_VERSION=''
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            CADDY_VERSION|XCADDY_VERSION) [[ "$value" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid pin: $key" ;;
            GO_MIN_VERSION) [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid Go minimum' ;;
            *) die "Unknown version key: $key" ;;
        esac
        [[ "$seen" != *" $key "* ]] || die "Duplicate version key: $key"
        seen="$seen$key "
        printf -v "$key" '%s' "$value"
    done < "$1"
    [[ -n "$CADDY_VERSION" && -n "$XCADDY_VERSION" && -n "$GO_MIN_VERSION" ]] || die 'Incomplete versions manifest'
}
load_plugins() {
    local enabled path version module extra seen=' '
    PLUGIN_ARGS=() PLUGIN_PATHS=() PLUGIN_VERSIONS=() PLUGIN_MODULES=()
    while read -r enabled path version module extra || [[ -n "$enabled" ]]; do
        [[ -z "$enabled" || "$enabled" == \#* ]] && continue
        [[ "$enabled" == 0 || "$enabled" == 1 ]] || die 'Plugin enabled must be 0 or 1'
        [[ "$path" =~ ^github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+$ && "$path" != *..* ]] || die 'Invalid plugin path'
        [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]] || die 'Plugin needs an exact Go version'
        [[ "$module" =~ ^[a-zA-Z0-9_.]+$ && -z "$extra" ]] || die 'Invalid plugin row'
        [[ "$seen" != *" $path "* ]] || die "Duplicate plugin: $path"
        seen="$seen$path "
        [[ "$enabled" == 1 ]] || continue
        PLUGIN_ARGS+=(--with "$path@$version")
        PLUGIN_PATHS+=("$path") PLUGIN_VERSIONS+=("$version") PLUGIN_MODULES+=("$module")
    done < "$1"
    [[ ${#PLUGIN_PATHS[@]} -gt 0 ]] || die 'No plugins enabled'
}
check_go() {
    need go
    local actual
    actual=$(GOTOOLCHAIN=local go env GOVERSION)
    actual=${actual#go}
    [[ "$actual" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Use a stable Go release: $actual"
    awk -v a="$actual" -v b="$GO_MIN_VERSION" 'BEGIN {split(a,x,"."); split(b,y,"."); for(i=1;i<=3;i++){if(x[i]>y[i])exit 0;if(x[i]<y[i])exit 1}}' || die "Go $GO_MIN_VERSION or newer required; found $actual"
}
exact_dep() {
    awk -v p="$2" -v v="$3" '$1=="dep" && $2==p && $3==v {found=1} END {exit !found}' "$1" || die "Resolved dependency drift: $2 (expected $3)"
}
verify_artifact() {
    local dir=$1 expected name extra
    [[ -d "$dir" && ! -L "$dir" ]] || die 'Artifact must be a real directory'
    for name in caddy versions.conf plugins.conf build-info.txt modules.txt SHA256SUMS; do
        [[ -f "$dir/$name" && ! -L "$dir/$name" ]] || die "Missing or symlinked artifact file: $name"
    done
    # Fixed filenames only; never let an untrusted checksum list name host files.
    for name in caddy versions.conf plugins.conf build-info.txt modules.txt; do
        expected=$(awk -v n="$name" '$2==n {print $1}' "$dir/SHA256SUMS")
        [[ "$expected" =~ ^[a-f0-9]{64}$ && "$(sha256 "$dir/$name")" == "$expected" ]] || die "Checksum mismatch: $name"
    done
    load_versions "$dir/versions.conf"
    load_plugins "$dir/plugins.conf"
    [[ -x "$dir/caddy" ]] || die 'Binary is not executable'
    [[ "$("$dir/caddy" version | awk '{print $1}')" == "$CADDY_VERSION" ]] || die 'Caddy version mismatch'
    "$dir/caddy" list-modules > /dev/null
    local mods i actual_info
    actual_info=$("$dir/caddy" build-info)
    [[ "$actual_info" != *'=>'* ]] || die 'Dependency replacements are not supported'
    mods=$("$dir/caddy" list-modules)
    for ((i=0;i<${#PLUGIN_PATHS[@]};i++)); do
        printf '%s\n' "$mods" | grep -Fxq "${PLUGIN_MODULES[$i]}" || die "Missing module: ${PLUGIN_MODULES[$i]}"
        exact_dep "$dir/build-info.txt" "${PLUGIN_PATHS[$i]}" "${PLUGIN_VERSIONS[$i]}"
        exact_dep /dev/stdin "${PLUGIN_PATHS[$i]}" "${PLUGIN_VERSIONS[$i]}" <<< "$actual_info"
    done
    exact_dep "$dir/build-info.txt" github.com/caddyserver/caddy/v2 "$CADDY_VERSION"
    exact_dep /dev/stdin github.com/caddyserver/caddy/v2 "$CADDY_VERSION" <<< "$actual_info"
}
