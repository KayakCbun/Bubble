#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swiftc -parse-as-library Sources/Bubble/AcpUpdateDelivery.swift scripts/check_acp_update_delivery.swift -o /tmp/bubble-check-acp-update-delivery
/tmp/bubble-check-acp-update-delivery

swiftc -parse-as-library Sources/Bubble/ProseFormat.swift scripts/check_prose.swift -o /tmp/bubble-check-prose
/tmp/bubble-check-prose

swiftc -O -parse-as-library \
  Sources/Bubble/ProseFormat.swift \
  Sources/Bubble/MarkdownFiles.swift \
  Sources/Bubble/OverlayLayoutPolicy.swift \
  Sources/Bubble/OverlaySurface.swift \
  Sources/Bubble/PierreFileIconCatalog.swift \
  Sources/Bubble/PierreFileIcon.swift \
  Sources/Bubble/WorkspaceTranscriptRenderPlan.swift \
  Sources/Bubble/TranscriptProse.swift \
  scripts/check_workspace_render_perf.swift \
  -o /tmp/bubble-check-workspace-render-perf
/tmp/bubble-check-workspace-render-perf

swiftc -O -parse-as-library \
  Sources/Bubble/WorkspaceTranscriptRenderPlan.swift \
  Sources/Bubble/TranscriptRenderPlan.swift \
  scripts/check_transcript_render_plan.swift \
  -o /tmp/bubble-check-transcript-render-plan
/tmp/bubble-check-transcript-render-plan

swiftc -parse-as-library Sources/Bubble/TranscriptStream.swift Sources/Bubble/ProseFormat.swift scripts/check_transcript_stream.swift -o /tmp/bubble-check-stream
/tmp/bubble-check-stream

swiftc -parse-as-library Sources/Bubble/OverlayLayoutPolicy.swift Sources/Bubble/OverlayRenderPolicy.swift scripts/check_overlay_layout.swift -o /tmp/bubble-check-layout
/tmp/bubble-check-layout

swiftc -parse-as-library Sources/Bubble/SideStage.swift Sources/Bubble/WorkspaceTranscriptRenderPlan.swift scripts/check_side_stage.swift -o /tmp/bubble-check-side-stage
/tmp/bubble-check-side-stage

swiftc -parse-as-library Sources/Bubble/TranscriptInteractionPolicy.swift scripts/check_transcript_interactions.swift -o /tmp/bubble-check-transcript-interactions
/tmp/bubble-check-transcript-interactions

swiftc -parse-as-library Sources/Bubble/HistoryRailPolicy.swift scripts/check_history_rail.swift -o /tmp/bubble-check-history-rail
/tmp/bubble-check-history-rail

swiftc -parse-as-library Sources/Bubble/OverlayComposer.swift scripts/check_composer.swift -o /tmp/bubble-check-composer
/tmp/bubble-check-composer

swiftc -parse-as-library Sources/Bubble/QuoteSelectionPolicy.swift Sources/Bubble/OverlayComposer.swift scripts/check_quote_selection.swift -o /tmp/bubble-check-quote-selection
/tmp/bubble-check-quote-selection

swiftc -parse-as-library Sources/Bubble/FileChangeSummaryPolicy.swift scripts/check_file_change_summary.swift -o /tmp/bubble-check-file-change-summary
/tmp/bubble-check-file-change-summary

swiftc -parse-as-library Sources/Bubble/PierreFileIconCatalog.swift scripts/check_pierre_file_icons.swift -o /tmp/bubble-check-pierre-file-icons
/tmp/bubble-check-pierre-file-icons

swiftc -parse-as-library Sources/Bubble/PromptTriggerPolicy.swift scripts/check_prompt_palette.swift -o /tmp/bubble-check-prompt-palette
/tmp/bubble-check-prompt-palette

swift run DiagramChecks

swiftc -parse-as-library Sources/Bubble/MessageDelivery.swift scripts/check_message_delivery.swift -o /tmp/bubble-check-message-delivery
/tmp/bubble-check-message-delivery

swiftc -parse-as-library Sources/Bubble/MarkdownFiles.swift scripts/check_markdown.swift -o /tmp/bubble-check-markdown
/tmp/bubble-check-markdown

swiftc -parse-as-library Sources/Bubble/CommandTapPolicy.swift scripts/check_command_tap.swift -o /tmp/bubble-check-tap
/tmp/bubble-check-tap

swiftc -parse-as-library Sources/Bubble/ConversationTree.swift scripts/check_conversation_tree.swift -o /tmp/bubble-check-conversation-tree
/tmp/bubble-check-conversation-tree

swiftc -parse-as-library Sources/Bubble/BubblePiAcpPatch.swift scripts/check_pi_acp_patch.swift -o /tmp/bubble-check-pi-acp-patch
/tmp/bubble-check-pi-acp-patch

swiftc -parse-as-library Sources/BubbleMounts/WorkspaceMounts.swift scripts/check_workspace_mounts.swift -o /tmp/bubble-check-mounts
/tmp/bubble-check-mounts

swiftc -parse-as-library \
  Sources/Bubble/JSONRPC.swift \
  Sources/Bubble/Paths.swift \
  Sources/Bubble/BubbleConfig.swift \
  Sources/Bubble/BubblePiAcpPatch.swift \
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
for bundle in MathJaxSwift_MathJaxSwift.bundle LaTeXSwiftUI_LaTeXSwiftUI.bundle; do
  if [[ -d "$(dirname "$BIN")/$bundle" ]]; then
    cp -R "$(dirname "$BIN")/$bundle" "$APP/$bundle"
  fi
done
mkdir -p "$RES/Avatar" "$RES/Mermaid"
cp -R "$ROOT/Resources/Avatar/." "$RES/Avatar/"
cp -R "$ROOT/Resources/Mermaid/." "$RES/Mermaid/"
if [[ -d "$ROOT/Resources/FileIcons" ]]; then
  mkdir -p "$RES/FileIcons"
  cp -R "$ROOT/Resources/FileIcons/." "$RES/FileIcons/"
fi

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
