#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${BUBBLE_BENCHMARK_APP_BIN:-$ROOT/dist/Bubble.app/Contents/MacOS/Bubble}"
TURNS="${BUBBLE_BENCHMARK_TURNS:-300}"
MAX_TOTAL_MS="${BUBBLE_BENCHMARK_MAX_TOTAL_MS:-260}"
MAX_PRESENT_MS="${BUBBLE_BENCHMARK_MAX_PRESENT_MS:-220}"

if [[ ! -x "$APP_BIN" ]]; then
  echo "FAIL: build Bubble first with ./scripts/package.sh" >&2
  exit 2
fi

BENCH_DIR="$(mktemp -d /tmp/bubble-session-switch.XXXXXX)"
FIXTURE_BIN="$BENCH_DIR/make-fixture"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$BENCH_DIR"
}
trap cleanup EXIT INT TERM

swiftc -parse-as-library "$ROOT/scripts/make_transcript_perf_fixture.swift" -o "$FIXTURE_BIN"
"$FIXTURE_BIN" --home "$BENCH_DIR" --turns "$TURNS" --side-session

LOG_FILE="$BENCH_DIR/.bubble/overlay.log"
env \
  CFFIXED_USER_HOME="$BENCH_DIR" \
  BUBBLE_SESSION_SWITCH_DIAGNOSTICS=1 \
  "$APP_BIN" --show >"$BENCH_DIR/bubble.stdout.log" 2>"$BENCH_DIR/bubble.stderr.log" &
APP_PID=$!

deadline=$((SECONDS + 30))
benchmark_line=""
while (( SECONDS < deadline )); do
  if [[ -f "$LOG_FILE" ]]; then
    benchmark_line="$(grep "session switch benchmark" "$LOG_FILE" | tail -1 || true)"
    if [[ -n "$benchmark_line" ]]; then
      break
    fi
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: benchmark app exited before producing a result" >&2
    exit 1
  fi
  sleep 0.1
done

if [[ -z "$benchmark_line" ]]; then
  echo "FAIL: no session switch benchmark result after 30 seconds" >&2
  exit 1
fi

present="$(sed -E 's/.* commitToPresented=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
total="$(sed -E 's/.* total=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
if ! awk -v actual="$present" -v limit="$MAX_PRESENT_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: session presentation ${present}ms exceeds ${MAX_PRESENT_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$total" -v limit="$MAX_TOTAL_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: session switch total ${total}ms exceeds ${MAX_TOTAL_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi

echo "PASS: $benchmark_line"
