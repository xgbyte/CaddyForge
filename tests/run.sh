#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/lib.sh
source "$ROOT/scripts/lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
count=0
pass() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
reject() { if ( "$@" ) >"$TMP/reject.log" 2>&1; then die "Expected rejection: $*"; fi; }
for file in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do bash -n "$file"; done
pass 'Bash syntax'
load_versions "$ROOT/config/versions.conf"
load_plugins "$ROOT/config/plugins.conf"
[[ ${#PLUGIN_PATHS[@]} -eq 2 ]] || die 'Default plugin profile changed without updating test'
pass 'Default profile excludes optional limiter'
# Intentional literal shell payload to verify parsing never executes it.
# shellcheck disable=SC2016
printf 'CADDY_VERSION=$(touch %s/pwned)\n' "$TMP" > "$TMP/evil"
reject load_versions "$TMP/evil"
[[ ! -e "$TMP/pwned" ]] || die 'Manifest executed shell code'
pass 'Manifest data cannot execute shell code'
cat "$ROOT/config/versions.conf" "$ROOT/config/versions.conf" > "$TMP/duplicate"
reject load_versions "$TMP/duplicate"
printf '1 github.com/foo/bar latest foo\n' > "$TMP/plugins"
reject load_plugins "$TMP/plugins"
pass 'Duplicate and floating versions rejected'
mkdir "$TMP/artifact"
A="$TMP/artifact"
cp "$ROOT/config/versions.conf" "$ROOT/config/plugins.conf" "$A/"
cat > "$A/caddy" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
version) echo 'v2.11.9 test' ;;
build-info) cat "$(dirname "$0")/build-info.txt" ;;
list-modules) printf '%s\n' http.handlers.waf dns.providers.cloudflare ;;
*) exit 1 ;;
esac
MOCK
chmod +x "$A/caddy"
printf 'dep github.com/caddyserver/caddy/v2 v2.11.9\ndep github.com/corazawaf/coraza-caddy/v2 v2.6.2\ndep github.com/caddy-dns/cloudflare v0.2.4\n' > "$A/build-info.txt"
"$A/caddy" list-modules > "$A/modules.txt"
checksums() {
    local file
    for file in caddy versions.conf plugins.conf build-info.txt modules.txt; do printf '%s  %s\n' "$(sha256 "$A/$file")" "$file"; done > "$A/SHA256SUMS"
}
checksums
verify_artifact "$A"
pass 'Complete fixture accepted'
printf 'tampered\n' >> "$A/caddy"
reject verify_artifact "$A"
pass 'Tampered binary rejected before execution'
sed -i.bak '/tampered/d' "$A/caddy"
sed -i.bak 's/v2.6.2/v2.6.1/' "$A/build-info.txt"
checksums
reject verify_artifact "$A"
pass 'Resolved dependency version drift rejected'
sed -i.bak 's/v2.6.1/v2.6.2/' "$A/build-info.txt"
sed -i.bak 's/http.handlers.waf/http.handlers.missing/' "$A/caddy"
checksums
reject verify_artifact "$A"
pass 'Missing registered module rejected'
# Each scenario runs in a separate process with EXIT/signal traps enabled.
for scenario in success validation restart health first signal recovery-fail; do
    mkdir -p "$TMP/$scenario/releases/old" "$TMP/$scenario/releases/new"
    if [[ "$scenario" != first ]]; then ln -s "$TMP/$scenario/releases/old" "$TMP/$scenario/current"; fi
    if bash "$ROOT/tests/transaction.sh" "$TMP/$scenario" "$scenario" > "$TMP/$scenario/log" 2>&1; then
        [[ "$scenario" == success ]] || die "Failure scenario passed: $scenario"
    else
        [[ "$scenario" != success ]] || { cat "$TMP/$scenario/log"; die 'Success scenario failed'; }
    fi
    if [[ "$scenario" == success ]]; then
        [[ "$(readlink "$TMP/$scenario/current")" == "$TMP/$scenario/releases/new" && "$(readlink "$TMP/$scenario/previous")" == "$TMP/$scenario/releases/old" ]] || die 'Success links wrong'
    elif [[ "$scenario" == first ]]; then
        [[ ! -L "$TMP/$scenario/current" ]] || die 'Failed first activation left current link'
        grep -q 'stop' "$TMP/$scenario/events" || die 'Failed first activation did not stop service'
    else
        [[ "$(readlink "$TMP/$scenario/current")" == "$TMP/$scenario/releases/old" && ! -L "$TMP/$scenario/previous" ]] || die "Recovery links wrong: $scenario"
        if [[ "$scenario" == recovery-fail ]]; then grep -q 'RECOVERY FAILED' "$TMP/$scenario/log" || die 'Recovery failure was hidden'; fi
    fi
    pass "Deployment transaction: $scenario (isolated doubles)"
done
printf '%s tests passed. No host services or managed paths touched.\n' "$count"
