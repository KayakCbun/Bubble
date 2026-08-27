#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${BUBBLE_BENCHMARK_APP_BIN:-$ROOT/dist/Bubble.app/Contents/MacOS/Bubble}"
TURNS="${BUBBLE_BENCHMARK_TURNS:-600}"
MODE="${BUBBLE_BENCHMARK_MODE:-display}"
MAX_P95_MS="${BUBBLE_BENCHMARK_MAX_P95_MS:-17}"
MAX_P99_MS="${BUBBLE_BENCHMARK_MAX_P99_MS:-18}"
MAX_READY_MS="${BUBBLE_BENCHMARK_MAX_READY_MS:-1500}"
MAX_PEAK_ANCHORS="${BUBBLE_BENCHMARK_MAX_PEAK_ANCHORS:-250}"
SCROLL_STEP="${BUBBLE_BENCHMARK_SCROLL_STEP:-32}"
MAX_JUMP_BLANK_SAMPLES="${BUBBLE_BENCHMARK_MAX_JUMP_BLANK_SAMPLES:-6}"
MAX_JUMP_BLANK_STREAK="${BUBBLE_BENCHMARK_MAX_JUMP_BLANK_STREAK:-1}"
HISTORY_TURNS="${BUBBLE_BENCHMARK_HISTORY_TURNS:-}"

if [[ "$MODE" != "display" && "$MODE" != "wheel" && "$MODE" != "mount-audit" && "$MODE" != "history-navigation-audit" ]]; then
  echo "FAIL: BUBBLE_BENCHMARK_MODE must be display, wheel, mount-audit, or history-navigation-audit" >&2
  exit 2
fi

if [[ "$MODE" == "display" ]]; then
  frontmost="$(swift -e 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")' 2>/dev/null)"
  if [[ "$frontmost" == "loginwindow" ]]; then
    echo "SKIP: unlock the desktop before running the display-linked scroll benchmark" >&2
    exit 3
  fi
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "FAIL: build Bubble first with ./scripts/package.sh" >&2
  exit 2
fi

BENCH_HOME="$(mktemp -d /tmp/bubble-scroll-benchmark.XXXXXX)"
FIXTURE_BIN="$BENCH_HOME/make-fixture"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$BENCH_HOME"
}
trap cleanup EXIT INT TERM

swiftc -parse-as-library "$ROOT/scripts/make_transcript_perf_fixture.swift" -o "$FIXTURE_BIN"
"$FIXTURE_BIN" --home "$BENCH_HOME" --turns "$TURNS"

LOG_FILE="$BENCH_HOME/.bubble/overlay.log"
STDERR_FILE="$BENCH_HOME/bubble.stderr.log"
diagnostics_mode="drive"
benchmark_pattern="transcript scroll benchmark"
if [[ "$MODE" == "wheel" ]]; then
  diagnostics_mode="wheel"
fi
if [[ "$MODE" == "mount-audit" ]]; then
  diagnostics_mode="mount-audit"
  benchmark_pattern="transcript mount audit"
fi
history_target=""
if [[ "$MODE" == "history-navigation-audit" ]]; then
  diagnostics_mode="history-navigation-audit"
  benchmark_pattern="history navigation audit"
  history_target="$(printf '00000000-0000-0000-0001-%012d' "$((TURNS - 5))")"
fi
benchmark_env=(
  HOME="$BENCH_HOME"
  CFFIXED_USER_HOME="$BENCH_HOME"
  BUBBLE_SCROLL_DIAGNOSTICS="$diagnostics_mode"
  BUBBLE_SCROLL_DIAGNOSTIC_STEP="$SCROLL_STEP"
)
if [[ -n "$HISTORY_TURNS" ]]; then
  benchmark_env+=(BUBBLE_TRANSCRIPT_HISTORY_TURNS="$HISTORY_TURNS")
fi
if [[ -n "$history_target" ]]; then
  benchmark_env+=(BUBBLE_HISTORY_NAVIGATION_AUDIT_TARGET="$history_target")
fi
env "${benchmark_env[@]}" "$APP_BIN" --show >"$BENCH_HOME/bubble.stdout.log" 2>"$STDERR_FILE" &
APP_PID=$!

deadline=$((SECONDS + 60))
benchmark_line=""
while (( SECONDS < deadline )); do
  if [[ -f "$LOG_FILE" ]]; then
    benchmark_line="$(grep "$benchmark_pattern" "$LOG_FILE" | tail -1 || true)"
    if [[ -n "$benchmark_line" ]]; then
      break
    fi
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: benchmark app exited before producing a result" >&2
    tail -40 "$STDERR_FILE" >&2 || true
    exit 1
  fi
  sleep 0.25
done

if [[ -z "$benchmark_line" ]]; then
  echo "FAIL: no $MODE benchmark result after 60 seconds" >&2
  tail -40 "$STDERR_FILE" >&2 || true
  exit 1
fi

if [[ "$MODE" == "history-navigation-audit" ]]; then
  offset="$(sed -E 's/.* offset=([^ ]+).*/\1/' <<<"$benchmark_line")"
  at_end="$(sed -E 's/.* atEnd=([01]).*/\1/' <<<"$benchmark_line")"
  if ! awk -v actual="$offset" 'BEGIN { exit !(actual >= -1.0 && actual <= 1.0) }'; then
    echo "FAIL: history target settled with ${offset}px top offset" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
  if (( at_end != 0 )); then
    echo "FAIL: middle history target incorrectly settled at the transcript end" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
  echo "PASS: $benchmark_line"
  exit 0
fi

peak_anchors="$(sed -E 's/.* peakAnchors=([0-9]+).*/\1/' <<<"$benchmark_line")"

if [[ "$MODE" == "display" || "$MODE" == "wheel" ]]; then
  ready="$(sed -E 's/.* ready=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
  p95="$(sed -E 's/.* p95=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
  p99="$(sed -E 's/.* p99=([0-9.]+)ms.*/\1/' <<<"$benchmark_line")"
  if ! awk -v actual="$ready" -v limit="$MAX_READY_MS" 'BEGIN { exit !(actual <= limit) }'; then
    echo "FAIL: first transcript window ${ready}ms exceeds ${MAX_READY_MS}ms" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
  if ! awk -v actual="$p95" -v limit="$MAX_P95_MS" 'BEGIN { exit !(actual <= limit) }'; then
    echo "FAIL: scroll p95 ${p95}ms exceeds ${MAX_P95_MS}ms" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
  if ! awk -v actual="$p99" -v limit="$MAX_P99_MS" 'BEGIN { exit !(actual <= limit) }'; then
    echo "FAIL: scroll p99 ${p99}ms exceeds ${MAX_P99_MS}ms" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
  blank_frames="$(sed -E 's/.* blankFrames=([0-9]+).*/\1/' <<<"$benchmark_line")"
  if (( blank_frames > 0 )); then
    echo "FAIL: found $blank_frames blank frames during continuous scrolling" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
fi
if (( peak_anchors > MAX_PEAK_ANCHORS )); then
  echo "FAIL: peak mounted anchors $peak_anchors exceeds $MAX_PEAK_ANCHORS" >&2
  echo "$benchmark_line" >&2
  exit 1
fi
if [[ "$MODE" == "mount-audit" ]]; then
  blank_samples="$(sed -E 's/.* blankSamples=([0-9]+).*/\1/' <<<"$benchmark_line")"
  longest_blank_streak="$(sed -E 's/.* longestBlankStreak=([0-9]+).*/\1/' <<<"$benchmark_line")"
  if (( blank_samples > MAX_JUMP_BLANK_SAMPLES || longest_blank_streak > MAX_JUMP_BLANK_STREAK )); then
    echo "FAIL: synthetic jumps found $blank_samples blank samples with a longest streak of $longest_blank_streak" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
  anchor_error="$(sed -E 's/.* anchorError=([^ ]+).*/\1/' <<<"$benchmark_line")"
  if ! awk -v actual="$anchor_error" 'BEGIN { exit !(actual <= 1.0) }'; then
    echo "FAIL: settled visible-anchor restore error ${anchor_error}px exceeds 1px" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
  coverage_mismatches="$(sed -E 's/.* coverageMismatches=([0-9]+).*/\1/' <<<"$benchmark_line")"
  if (( coverage_mismatches > 0 )); then
    echo "FAIL: history indicator coverage disagreed with live mounted rows in $coverage_mismatches samples" >&2
    echo "$benchmark_line" >&2
    exit 1
  fi
fi

echo "PASS: $benchmark_line"
