#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${BUBBLE_BENCHMARK_APP_BIN:-$ROOT/dist/Bubble.app/Contents/MacOS/Bubble}"
CYCLES="${BUBBLE_FILE_CHANGE_CYCLES:-12}"
# P95 is the 60 Hz interaction gate. P99 permits one compositor/run-loop miss
# so host scheduling noise does not make the red/green regression signal flaky.
MAX_FRAME_P95_MS="${BUBBLE_FILE_CHANGE_MAX_FRAME_P95_MS:-17}"
MAX_FRAME_P99_MS="${BUBBLE_FILE_CHANGE_MAX_FRAME_P99_MS:-34}"
MAX_LATENCY_P95_MS="${BUBBLE_FILE_CHANGE_MAX_LATENCY_P95_MS:-25}"
FILES="${BUBBLE_FILE_CHANGE_FILES:-1}"
MIN_EXPANDED_HEIGHT="${BUBBLE_FILE_CHANGE_MIN_EXPANDED_HEIGHT:-20}"

if [[ ! -x "$APP_BIN" ]]; then
  echo "FAIL: build Bubble first with ./scripts/package.sh" >&2
  exit 2
fi

BENCH_HOME="$(mktemp -d /tmp/bubble-file-change-benchmark.XXXXXX)"
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

swiftc -parse-as-library "$ROOT/scripts/make_transcript_perf_fixture.swift" -o "$FIXTURE_BIN"
"$FIXTURE_BIN" --home "$BENCH_HOME" --turns 1 --file-change-files "$FILES"

LOG_FILE="$BENCH_HOME/.bubble/overlay.log"
STDERR_FILE="$BENCH_HOME/bubble.stderr.log"
benchmark_env=(
  HOME="$BENCH_HOME" \
  CFFIXED_USER_HOME="$BENCH_HOME" \
  BUBBLE_FILE_CHANGE_DIAGNOSTICS=1 \
  BUBBLE_FILE_CHANGE_CYCLES="$CYCLES"
)
env "${benchmark_env[@]}" "$APP_BIN" >"$BENCH_HOME/bubble.stdout.log" 2>"$STDERR_FILE" &
APP_PID=$!

deadline=$((SECONDS + 30))
benchmark_line=""
while (( SECONDS < deadline )); do
  if [[ -f "$LOG_FILE" ]]; then
    benchmark_line="$(grep "file change presentation benchmark" "$LOG_FILE" | tail -1 || true)"
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
  echo "FAIL: no file change benchmark result after 30 seconds" >&2
  tail -40 "$STDERR_FILE" >&2 || true
  exit 1
fi

presented="$(sed -E 's/.* presented=([0-9]+).*/\1/' <<<"$benchmark_line")"
expanded="$(sed -E 's/.* expanded=([0-9]+).*/\1/' <<<"$benchmark_line")"
expanded_min_height="$(sed -E 's/.* expandedMinHeight=([0-9.]+).*/\1/' <<<"$benchmark_line")"
frame_p95="$(sed -E 's/.* frameP95=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
frame_p99="$(sed -E 's/.* frameP99=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
latency_p95="$(sed -E 's/.* latencyP95=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"

if (( presented != CYCLES )); then
  echo "FAIL: only $presented of $CYCLES file change toggles presented" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
expected_expansions=$(((CYCLES + 1) / 2))
if (( expanded != expected_expansions )); then
  echo "FAIL: only $expanded of $expected_expansions expansions exposed measurable content" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$expanded_min_height" -v limit="$MIN_EXPANDED_HEIGHT" 'BEGIN { exit !(actual >= limit) }'; then
  echo "FAIL: expanded file content height ${expanded_min_height}pt is below ${MIN_EXPANDED_HEIGHT}pt" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$frame_p95" -v limit="$MAX_FRAME_P95_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: file change frame p95 ${frame_p95}ms exceeds ${MAX_FRAME_P95_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$frame_p99" -v limit="$MAX_FRAME_P99_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: file change frame p99 ${frame_p99}ms exceeds ${MAX_FRAME_P99_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if ! awk -v actual="$latency_p95" -v limit="$MAX_LATENCY_P95_MS" 'BEGIN { exit !(actual <= limit) }'; then
  echo "FAIL: file change latency p95 ${latency_p95}ms exceeds ${MAX_LATENCY_P95_MS}ms" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
echo "PASS: $benchmark_line"
