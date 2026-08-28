#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${BUBBLE_BENCHMARK_APP_BIN:-$ROOT/dist/Bubble.app/Contents/MacOS/Bubble}"
CYCLES="${BUBBLE_PALETTE_CYCLES:-20}"
MAX_P99_MS="${BUBBLE_PALETTE_MAX_P99_MS:-17}"
MAX_LATENCY_P95_MS="${BUBBLE_PALETTE_MAX_LATENCY_P95_MS:-17}"

if [[ ! -x "$APP_BIN" ]]; then
  echo "FAIL: build Bubble first" >&2
  exit 2
fi

BENCH_HOME="$(mktemp -d /tmp/bubble-palette-benchmark.XXXXXX)"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  /usr/bin/trash "$BENCH_HOME" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

LOG_FILE="$BENCH_HOME/.bubble/overlay.log"
STDERR_FILE="$BENCH_HOME/bubble.stderr.log"
env \
  HOME="$BENCH_HOME" \
  CFFIXED_USER_HOME="$BENCH_HOME" \
  BUBBLE_PALETTE_DIAGNOSTICS=1 \
  BUBBLE_PALETTE_CYCLES="$CYCLES" \
  "$APP_BIN" >"$BENCH_HOME/bubble.stdout.log" 2>"$STDERR_FILE" &
APP_PID=$!

deadline=$((SECONDS + 30))
benchmark_line=""
while (( SECONDS < deadline )); do
  if [[ -f "$LOG_FILE" ]]; then
    benchmark_line="$(grep "palette presentation benchmark" "$LOG_FILE" | tail -1 || true)"
    if [[ -n "$benchmark_line" ]]; then
      break
    fi
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: benchmark app exited before producing a result" >&2
    tail -40 "$STDERR_FILE" >&2 || true
    exit 1
  fi
  sleep 0.1
done

if [[ -z "$benchmark_line" ]]; then
  echo "FAIL: no palette benchmark result after 30 seconds" >&2
  tail -40 "$STDERR_FILE" >&2 || true
  exit 1
fi

presented="$(sed -E 's/.* presented=([0-9]+).*/\1/' <<<"$benchmark_line")"
show_p99="$(sed -E 's/.* showP99=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
latency_p95="$(sed -E 's/.* latencyP95=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
if (( presented != CYCLES )); then
  echo "FAIL: only $presented of $CYCLES palettes were presented" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$show_p99" -v limit="$MAX_P99_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: palette show p99 ${show_p99}ms exceeds ${MAX_P99_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$latency_p95" -v limit="$MAX_LATENCY_P95_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: palette latency p95 ${latency_p95}ms exceeds ${MAX_LATENCY_P95_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi

echo "PASS: $benchmark_line"
