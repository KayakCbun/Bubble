#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/package.sh"

# A rebuilt unsigned binary looks like a new app to macOS; quit the previous one.
pkill -f "Bubble.app/Contents/MacOS/Bubble" 2>/dev/null || true
pkill -f "FxOverlay.app/Contents/MacOS/FxOverlay" 2>/dev/null || true
open "$ROOT/dist/Bubble.app" --args --show
echo "Launched Bubble. Double-tap Command, or click the menu bar icon."
