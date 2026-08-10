#!/usr/bin/env bash
# Warm lint daemon driver for cajeta-coco development.
#
# The cajeta front end pays ~70s of stdlib priming per process, which makes a
# per-edit `cajeta --lint` loop unusable. `--lint-server` primes once and then
# answers NDJSON requests warm, so this script keeps one server alive and
# funnels individual file checks through it.
#
#   tools/lintd.sh start          # prime the server (~70s, once)
#   tools/lintd.sh check <file>   # lint one file, warm
#   tools/lintd.sh stop
#
# The server is fully detached (setsid) and a holder process keeps the request
# FIFO open for writing, so neither the calling shell exiting nor an individual
# `check` closing its write end sends the server EOF.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAJETA="${CAJETA:-/home/julian/code/cpp/cajeta/build/src/cajeta}"
SRC="$ROOT/src/main/cajeta"
RUN="$ROOT/.coco-lintd"
FIFO="$RUN/in"
OUT="$RUN/out.ndjson"
PIDF="$RUN/pid"
HOLDF="$RUN/holder.pid"

start() {
    stop >/dev/null 2>&1
    mkdir -p "$RUN"
    rm -f "$FIFO" "$OUT"
    mkfifo "$FIFO"
    : > "$OUT"

    # Holder: keeps the FIFO's write end open for the server's lifetime.
    setsid bash -c 'exec 9>"$1"; while :; do sleep 3600; done' _ "$FIFO" \
        >/dev/null 2>&1 &
    echo $! > "$HOLDF"

    setsid "$CAJETA" --lint-server --source-root "$SRC" --diag-format=json \
        < "$FIFO" > "$OUT" 2>"$RUN/err.log" &
    echo $! > "$PIDF"
    echo "lintd: priming (~70s)..."
}

wait_ready() {
    for _ in $(seq 1 240); do
        grep -q '"kind":"server"' "$OUT" 2>/dev/null && { echo "lintd: ready"; return 0; }
        kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null || {
            echo "lintd: server died; see $RUN/err.log" >&2; tail -20 "$RUN/err.log" >&2; return 1; }
        sleep 1
    done
    echo "lintd: timed out" >&2; return 1
}

check() {
    local file="$1"
    [ -p "$FIFO" ] || { echo "lintd: not running" >&2; return 1; }
    local before; before=$(wc -l < "$OUT")
    local id=$((RANDOM % 100000))
    printf '{"kind":"lint","id":%s,"file":"%s","emitXref":false}\n' "$id" "$file" > "$FIFO"
    for _ in $(seq 1 900); do
        if tail -n +$((before + 1)) "$OUT" 2>/dev/null | grep -q "\"kind\":\"done\",\"id\":$id"; then
            tail -n +$((before + 1)) "$OUT" | grep -v '"kind":"done"' | grep -v '"kind":"server"'
            return 0
        fi
        sleep 0.1
    done
    echo "lintd: timeout" >&2; return 1
}

stop() {
    for f in "$PIDF" "$HOLDF"; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    done
    rm -rf "$RUN"
    echo "lintd: stopped"
}

case "${1:-}" in
    start) start ;;
    ready) wait_ready ;;
    check) shift; check "$@" ;;
    stop)  stop ;;
    *) echo "usage: lintd.sh {start|ready|check <file>|stop}" >&2; exit 2 ;;
esac
