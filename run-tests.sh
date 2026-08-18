#!/usr/bin/env bash
# Build + run the cajeta-coco unit tests.
#
# The suite lives under src/test/cajeta and is driven by cajeta-unit's
# reflective @Test discovery (dev.cajeta.unit.Runner).
#
# Library and test sources are compiled TOGETHER under --profile=test into one
# executable, with cajeta-unit supplied as a .cja classpath dep. Reflective
# discovery walks the final binary, so the engine's classes and the tests must
# be in the same compile.
#
# This script exists because `cajeta build` does not resolve dev-dependencies —
# only runtime ones — so nothing else would put a cajeta-unit archive on the
# classpath. Adapted from cajeta-logging's run-tests.sh, which is the mature
# version of this same problem.
#
# cajeta-unit resolution, in order:
#   1. $UNIT_CJA        — explicit archive path, used verbatim
#   2. $UNIT_REPO       — a checkout (default ../cajeta-unit): build it and use
#                         whatever version it emits. The local-dev flow.
#                         NOTE: coco lives under ~/code/cajeta while cajeta-unit
#                         lives under ~/code/cpp, so the default sibling path
#                         does NOT resolve here — set UNIT_REPO explicitly for
#                         the checkout flow.
#   3. $OLLA_HOME store — an installed dev.cajeta.unit at the version pinned in
#                         cajeta.json's dev-dependencies
#   4. Olla registry    — /v2/resolve + /v2/blob, sha256-verified, cached under
#                         build/. The CI flow: bare runners have no checkout.
# The version for 3/4 comes from cajeta.json — the single source of truth.
#
# Env:
#   CAJETA     — compiler binary (default: cajeta on PATH)
#   UNIT_CJA   — explicit cajeta-unit .cja (skips all resolution)
#   UNIT_REPO  — path to a cajeta-unit checkout (default: ../cajeta-unit)
#   OLLA_HOME  — local package store (default: ~/.olla)
#   OLLA_URL   — registry base (default: https://olla.cajeta.dev)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CAJETA="${CAJETA:-cajeta}"
UNIT_REPO="${UNIT_REPO:-$here/../cajeta-unit}"
OLLA_HOME="${OLLA_HOME:-$HOME/.olla}"
OLLA_URL="${OLLA_URL:-https://olla.cajeta.dev}"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1;
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- resolve the cajeta-unit archive -----------------------------------------
unit_cja="${UNIT_CJA:-}"

if [[ -z "$unit_cja" && -d "$UNIT_REPO" ]]; then
    echo ">> building cajeta-unit from checkout ($UNIT_REPO)"
    ( cd "$UNIT_REPO" && "$CAJETA" build >/dev/null )
    unit_cja="$(ls -t "$UNIT_REPO"/build/archive/dev.cajeta.unit-*.cja 2>/dev/null | head -1)"
fi

if [[ -z "$unit_cja" ]]; then
    UNIT_VER="$(sed -n 's/.*"dev\.cajeta\.unit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$here/cajeta.json" | head -1)"
    if [[ -z "$UNIT_VER" ]]; then
        echo "run-tests.sh: no dev.cajeta.unit pin in cajeta.json dev-dependencies" >&2
        exit 1
    fi

    store_cja="$OLLA_HOME/dev.cajeta.unit/$UNIT_VER/dev.cajeta.unit-$UNIT_VER.cja"
    cache_cja="$here/build/.unit-cache/dev.cajeta.unit-$UNIT_VER.cja"
    if [[ -f "$store_cja" ]]; then
        unit_cja="$store_cja"
    elif [[ -f "$cache_cja" ]]; then
        unit_cja="$cache_cja"
    else
        echo ">> fetching dev.cajeta.unit $UNIT_VER from $OLLA_URL"
        meta="$(curl -fsS "$OLLA_URL/v2/resolve?name=dev.cajeta.unit&version=$UNIT_VER")"
        sha="$(printf '%s' "$meta" | sed -n 's/.*"sha256":"sha256:\([0-9a-f]*\)".*/\1/p')"
        if [[ -z "$sha" ]]; then
            echo "run-tests.sh: /v2/resolve gave no sha256 for dev.cajeta.unit $UNIT_VER" >&2
            exit 1
        fi
        mkdir -p "$(dirname "$cache_cja")"
        curl -fsS -o "$cache_cja" "$OLLA_URL/v2/blob/$sha"
        got="$(sha256_of "$cache_cja")"
        if [[ "$got" != "$sha" ]]; then
            rm -f "$cache_cja"
            echo "run-tests.sh: sha256 mismatch fetching dev.cajeta.unit $UNIT_VER" >&2
            echo "  expected $sha" >&2
            echo "  got      $got" >&2
            exit 1
        fi
        unit_cja="$cache_cja"
    fi
fi

if [[ ! -f "$unit_cja" ]]; then
    echo "run-tests.sh: could not resolve a dev.cajeta.unit archive" >&2
    echo "  set UNIT_REPO to a cajeta-unit checkout, or UNIT_CJA to an archive" >&2
    exit 1
fi
echo ">> cajeta-unit: $unit_cja"

# --- resolve coco's own runtime dependencies ---------------------------------
# Unlike cajeta-logging (no runtime deps), coco imports dev.cajeta.xref in
# analysis/CallGraph.cajeta. `cajeta build` resolves runtime dependencies into
# .cajeta/cache/downloads/; a direct compiler invocation does not, so without
# this the test build dies with
#   CAJETA_ERROR_UNKNOWN_TYPE: unknown field type 'XrefDoc'
# Run a build first to populate the cache, then put each pinned dependency on the
# COMMA-separated classpath (--classpath=a.cja,b.cja; a colon list is read as one
# path and fails with "CajetaArchive: cannot open").
# the classpath. Versions come from cajeta.json, so a bump cannot leave a stale
# archive silently linked.
echo ">> resolving runtime dependencies"
( cd "$here" && "$CAJETA" build >/dev/null )

cp_parts=("$unit_cja")
while IFS=$'\t' read -r dep ver; do
    [[ -z "$dep" ]] && continue
    dep_cja="$here/.cajeta/cache/downloads/$dep-$ver.cja"
    if [[ ! -f "$dep_cja" ]]; then
        echo "run-tests.sh: dependency $dep $ver not resolved at $dep_cja" >&2
        exit 1
    fi
    cp_parts+=("$dep_cja")
done < <(sed -n '/"dependencies"[[:space:]]*:[[:space:]]*{/,/}/p' "$here/cajeta.json" \
         | sed -n 's/.*"\(dev\.cajeta\.[a-z]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1\t\2/p')

classpath="$(IFS=,; echo "${cp_parts[*]}")"
echo ">> classpath: $classpath"

# --- build + run --------------------------------------------------------------
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# Merge library + test sources into one root so reflective discovery sees both
# in the final --profile=test binary (see header).
srcroot="$out/src"
mkdir -p "$srcroot"
cp -r "$here/src/main/cajeta/." "$srcroot/"
cp -r "$here/src/test/cajeta/." "$srcroot/"

echo ">> building + running the test binary (lib+test sources, --profile=test)"
"$CAJETA" --emit=exe --profile=test \
    --classpath="$classpath" \
    -o "$out/cocotests" \
    cajeta.coco.selftest.TestMain.run "$srcroot" "$out/build" >/dev/null

"$out/cocotests"
