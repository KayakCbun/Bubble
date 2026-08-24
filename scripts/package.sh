#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swiftc -parse-as-library Sources/Bubble/AcpUpdateDelivery.swift scripts/check_acp_update_delivery.swift -o /tmp/bubble-check-acp-update-delivery
/tmp/bubble-check-acp-update-delivery

swiftc -parse-as-library Sources/Bubble/ProseFormat.swift scripts/check_prose.swift -o /tmp/bubble-check-prose
/tmp/bubble-check-prose

swiftc -parse-as-library Sources/Bubble/TranscriptStream.swift Sources/Bubble/ProseFormat.swift scripts/check_transcript_stream.swift -o /tmp/bubble-check-stream
/tmp/bubble-check-stream

swiftc -parse-as-library Sources/Bubble/OverlayLayoutPolicy.swift scripts/check_overlay_layout.swift -o /tmp/bubble-check-layout
/tmp/bubble-check-layout

swiftc -parse-as-library Sources/Bubble/OverlayComposer.swift scripts/check_composer.swift -o /tmp/bubble-check-composer
/tmp/bubble-check-composer

swiftc -parse-as-library Sources/Bubble/MessageDelivery.swift scripts/check_message_delivery.swift -o /tmp/bubble-check-message-delivery
/tmp/bubble-check-message-delivery

swiftc -parse-as-library Sources/Bubble/MarkdownFiles.swift scripts/check_markdown.swift -o /tmp/bubble-check-markdown
/tmp/bubble-check-markdown

swiftc -parse-as-library Sources/Bubble/CommandTapPolicy.swift scripts/check_command_tap.swift -o /tmp/bubble-check-tap
/tmp/bubble-check-tap

swiftc -parse-as-library Sources/BubbleMounts/WorkspaceMounts.swift scripts/check_workspace_mounts.swift -o /tmp/bubble-check-mounts
/tmp/bubble-check-mounts

swiftc -parse-as-library \
  Sources/Bubble/JSONRPC.swift \
  Sources/Bubble/Paths.swift \
  Sources/Bubble/BubbleConfig.swift \
  Sources/Bubble/PiSetup.swift \
  scripts/check_pi_setup.swift \
  -o /tmp/bubble-check-setup
/tmp/bubble-check-setup

swift build -c release --product Bubble

BIN="$(swift build -c release --show-bin-path)/Bubble"
APP="$ROOT/dist/Bubble.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP" "$ROOT/dist/FxOverlay.app"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/Bubble"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$RES/Avatar" "$RES/Mermaid"
cp -R "$ROOT/Resources/Avatar/." "$RES/Avatar/"
cp -R "$ROOT/Resources/Mermaid/." "$RES/Mermaid/"

ICON_SRC="$ROOT/Resources/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

xattr -cr "$APP" 2>/dev/null || true

echo "Built $APP"
