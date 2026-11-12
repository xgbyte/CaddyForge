#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[[ $# -ge 1 && $# -le 2 ]] || die 'Usage: build.sh NEW_ARTIFACT_DIRECTORY [PLUGINS_MANIFEST]'
"$CF_ROOT/scripts/bootstrap.sh"
load_versions "$CF_ROOT/config/versions.conf"
plugins_file=${2:-$CF_ROOT/config/plugins.conf}
load_plugins "$plugins_file"
# Native builds are mandatory: verification must execute the resulting binary.
[[ "${GOOS:-$(go env GOHOSTOS)}" == "$(go env GOHOSTOS)" && "${GOARCH:-$(go env GOHOSTARCH)}" == "$(go env GOHOSTARCH)" ]] || die 'Cross compilation is unsupported; use a native runner'
export GOTOOLCHAIN=local CGO_ENABLED=0
out=$1
[[ ! -e "$out" && ! -L "$out" ]] || die 'Output already exists; use a new artifact directory'
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.caddyforge-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp "$CF_ROOT/config/versions.conf" "$stage/versions.conf"
cp "$plugins_file" "$stage/plugins.conf"
"$CF_ROOT/.tools/xcaddy" build "$CADDY_VERSION" "${PLUGIN_ARGS[@]}" --output "$stage/caddy"
go version -m "$stage/caddy" > "$stage/build-info.txt"
"$stage/caddy" list-modules > "$stage/modules.txt"
for name in caddy versions.conf plugins.conf build-info.txt modules.txt; do
    printf '%s  %s\n' "$(sha256 "$stage/$name")" "$name"
done > "$stage/SHA256SUMS"
verify_artifact "$stage"
"$stage/caddy" validate --adapter caddyfile --config "$CF_ROOT/examples/Caddyfile"
if printf '%s\n' "${PLUGIN_MODULES[@]}" | grep -Fxq http.handlers.waf; then
    "$stage/caddy" validate --adapter caddyfile --config "$CF_ROOT/examples/Caddyfile.coraza"
fi
if printf '%s\n' "${PLUGIN_MODULES[@]}" | grep -Fxq http.handlers.rate_limit; then
    "$stage/caddy" validate --adapter caddyfile --config "$CF_ROOT/examples/Caddyfile.ratelimit"
fi
# mv -T is Linux-only; output existence was checked above. Use a unique output per build.
mv "$stage" "$out"
printf 'Verified artifact: %s\n' "$out"
