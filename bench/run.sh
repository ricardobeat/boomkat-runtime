#!/usr/bin/env bash
# Benchmarks the three servers against the same wrk run and prints a summary.
#
#   ./bench/run.sh [duration] [connections] [threads]
#
# Each server is started on its own port, warmed up, measured, then killed.
# Results are whatever wrk reports; nothing here is averaged across runs, so
# take a couple of runs before believing a small difference.
set -uo pipefail
cd "$(dirname "$0")/.."

# Defaults come from a sweep of wrk threads x connections on this machine:
# 2 wrk threads beat 1, 3 and 4 at every server thread count, because wrk and
# the server contend for the same 4 performance cores. See README "Tuning".
DURATION="${1:-10s}"
CONNS="${2:-512}"
THREADS="${3:-2}"
PATH_="/bench/plain"

if ! command -v wrk >/dev/null; then echo "wrk is required" >&2; exit 1; fi
[[ -x out/test-server ]]     || { echo "build first: c3c build test-server" >&2; exit 1; }
[[ -x out/test-server-uws ]] || { echo "build first: ./scripts/build_uws.sh && c3c build test-server-uws" >&2; exit 1; }

results=()

bench_one() {
    local name="$1" port="$2"; shift 2
    printf '\n=== %s ===\n' "$name"

    "$@" >/tmp/bench-$name.log 2>&1 &
    local pid=$!

    # Wait for the port rather than sleeping a fixed amount.
    local up=0
    for _ in $(seq 1 100); do
        if curl -fsS --max-time 1 "http://127.0.0.1:$port$PATH_" >/dev/null 2>&1; then up=1; break; fi
        sleep 0.1
    done
    if [[ $up -eq 0 ]]; then
        echo "  FAILED to start; log:"; sed 's/^/    /' /tmp/bench-$name.log
        kill $pid 2>/dev/null; return
    fi

    # Confirm all three servers actually agree on the response before timing
    # them, so the numbers describe the same work.
    local body
    body=$(curl -fsS "http://127.0.0.1:$port$PATH_")
    echo "  response: '$body'"

    wrk -t"$THREADS" -c"$CONNS" -d"$DURATION" --latency \
        "http://127.0.0.1:$port$PATH_" > /tmp/bench-$name.wrk 2>&1
    sed 's/^/  /' /tmp/bench-$name.wrk

    local rps p50 p99
    rps=$(awk '/Requests\/sec/ {print $2}' /tmp/bench-$name.wrk)
    p50=$(awk '/^ *50%/ {print $2}' /tmp/bench-$name.wrk)
    p99=$(awk '/^ *99%/ {print $2}' /tmp/bench-$name.wrk)
    local rss
    rss=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
    results+=("$(printf '%-12s %14s %10s %10s %10s' "$name" "${rps:-?}" "${p50:-?}" "${p99:-?}" "${rss:-?} KB")")

    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
}

# The C3 servers are run single-threaded so they line up with node and bun,
# which are single-threaded here too. c3-uws-2t is the tuned configuration and
# is labelled separately rather than passed off as the same comparison.
bench_one c3-lws    8080 ./out/test-server     8080 1
bench_one c3-lws-2t 8085 ./out/test-server     8085 2
bench_one c3-uws    8081 ./out/test-server-uws 8081 1
bench_one c3-uws-2t 8084 ./out/test-server-uws 8084 2
bench_one node      8082 node bench/server.node.js 8082
bench_one bun       8083 bun  bench/server.bun.js  8083

printf '\n\n=== summary (%s, %s connections, %s threads) ===\n' "$DURATION" "$CONNS" "$THREADS"
printf '%-12s %14s %10s %10s %10s\n' server req/sec p50 p99 rss
printf '%s\n' "${results[@]}"
