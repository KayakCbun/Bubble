#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${BUBBLE_BENCHMARK_APP_BIN:-$ROOT/dist/Bubble.app/Contents/MacOS/Bubble}"
MAX_P95_MS="${BUBBLE_PRESENTATION_MAX_P95_MS:-17}"
MAX_P99_MS="${BUBBLE_PRESENTATION_MAX_P99_MS:-20}"
MAX_FRAME_MUTATIONS="${BUBBLE_PRESENTATION_MAX_FRAME_MUTATIONS:-0}"
CYCLES="${BUBBLE_PRESENTATION_CYCLES:-30}"
TURNS="${BUBBLE_PRESENTATION_TURNS:-600}"
MIN_PRESENTATION_SAMPLES="${BUBBLE_PRESENTATION_MIN_SAMPLES:-360}"

if [[ ! -x "$APP_BIN" ]]; then
  echo "FAIL: build Bubble first with ./scripts/package.sh" >&2
  exit 2
fi

BENCH_HOME="$(mktemp -d /tmp/bubble-presentation-benchmark.XXXXXX)"
FIXTURE_BIN="$BENCH_HOME/make-fixture"
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
swiftc -parse-as-library "$ROOT/scripts/make_transcript_perf_fixture.swift" -o "$FIXTURE_BIN"
"$FIXTURE_BIN" --home "$BENCH_HOME" --turns "$TURNS"
env \
  HOME="$BENCH_HOME" \
  CFFIXED_USER_HOME="$BENCH_HOME" \
  BUBBLE_PRESENTATION_DIAGNOSTICS=1 \
  BUBBLE_PRESENTATION_CYCLES="$CYCLES" \
  "$APP_BIN" >"$BENCH_HOME/bubble.stdout.log" 2>"$STDERR_FILE" &
APP_PID=$!

deadline=$((SECONDS + 45))
benchmark_line=""
while (( SECONDS < deadline )); do
  if [[ -f "$LOG_FILE" ]]; then
    benchmark_line="$(grep "window presentation benchmark" "$LOG_FILE" | tail -1 || true)"
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
  echo "FAIL: no window presentation benchmark result after 45 seconds" >&2
  tail -40 "$STDERR_FILE" >&2 || true
  exit 1
fi

p95="$(sed -E 's/.* p95=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
p99="$(sed -E 's/.* p99=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
frame_mutations="$(sed -E 's/.* frameMutations=([0-9]+).*/\1/' <<<"$benchmark_line")"
presentation_samples="$(sed -E 's/.* presentationSamples=([0-9]+).*/\1/' <<<"$benchmark_line")"

if ! awk -v actual="$p95" -v limit="$MAX_P95_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: presentation p95 ${p95}ms exceeds ${MAX_P95_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$p99" -v limit="$MAX_P99_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: presentation p99 ${p99}ms exceeds ${MAX_P99_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if (( frame_mutations > MAX_FRAME_MUTATIONS )); then
  echo "FAIL: window frame changed $frame_mutations times during visibility transitions" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if (( presentation_samples < MIN_PRESENTATION_SAMPLES )); then
  echo "FAIL: only $presentation_samples compositor presentation samples were observed" >&2
  echo "$benchmark_line" >&2
  exit 1
fi

echo "PASS: $benchmark_line"
