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
  Sources/Bubble/PreviewFiles.swift \
  Sources/Bubble/OverlayLayoutPolicy.swift \
  Sources/Bubble/OverlaySurface.swift \
  Sources/Bubble/PierreFileIconCatalog.swift \
  Sources/Bubble/PierreFileIcon.swift \
  Sources/Bubble/WorkspaceTranscriptRenderPlan.swift \
  Sources/Bubble/TranscriptProse.swift \
  scripts/check_workspace_render_perf.swift \
  -o /tmp/bubble-check-workspace-render-perf
/tmp/bubble-check-workspace-render-perf

swiftc -parse-as-library -framework AppKit -framework SwiftUI \
  Sources/Bubble/TranscriptHostingSizingPolicy.swift \
  scripts/check_hosting_view_sizing.swift \
  -o /tmp/bubble-check-hosting-view-sizing
/tmp/bubble-check-hosting-view-sizing

swiftc -O -parse-as-library \
  Sources/Bubble/WorkspaceTranscriptRenderPlan.swift \
  Sources/Bubble/TranscriptRenderPlan.swift \
  scripts/check_transcript_render_plan.swift \
  -o /tmp/bubble-check-transcript-render-plan
/tmp/bubble-check-transcript-render-plan

swiftc -O -parse-as-library \
  Sources/Bubble/WorkspaceTranscriptRenderPlan.swift \
  Sources/Bubble/TranscriptRenderPlan.swift \
  Sources/Bubble/TranscriptProjectionStore.swift \
  scripts/check_transcript_projection_store.swift \
  -o /tmp/bubble-check-transcript-projection-store
/tmp/bubble-check-transcript-projection-store

swiftc -parse-as-library \
  Sources/Bubble/TranscriptHistoryWindow.swift \
  Sources/Bubble/TranscriptRestoreMerge.swift \
  scripts/check_transcript_history_window.swift \
  -o /tmp/bubble-check-transcript-history-window
/tmp/bubble-check-transcript-history-window

swiftc -parse-as-library Sources/Bubble/TranscriptStream.swift Sources/Bubble/ProseFormat.swift scripts/check_transcript_stream.swift -o /tmp/bubble-check-stream
/tmp/bubble-check-stream

swiftc -parse-as-library scripts/check_escape_dispatch.swift -o /tmp/bubble-check-escape-dispatch
/tmp/bubble-check-escape-dispatch

swiftc -parse-as-library scripts/check_typography_contract.swift -o /tmp/bubble-check-typography-contract
/tmp/bubble-check-typography-contract

swiftc -parse-as-library Sources/Bubble/OverlayLayoutPolicy.swift Sources/Bubble/OverlayRenderPolicy.swift scripts/check_overlay_layout.swift -o /tmp/bubble-check-layout
/tmp/bubble-check-layout

swiftc -parse-as-library -framework AppKit -framework SwiftUI scripts/check_running_sweep_layout.swift -o /tmp/bubble-check-running-sweep-layout
/tmp/bubble-check-running-sweep-layout

swiftc -O -parse-as-library -framework AppKit \
  Sources/Bubble/OverlayLayoutPolicy.swift \
  Sources/Bubble/OverlayRenderPolicy.swift \
  Sources/Bubble/ComposerEditorLocator.swift \
  scripts/check_composer_editor.swift \
  -o /tmp/bubble-check-composer-editor
/tmp/bubble-check-composer-editor

swiftc -parse-as-library Sources/Bubble/SideStage.swift Sources/Bubble/WorkspaceTranscriptRenderPlan.swift scripts/check_side_stage.swift -o /tmp/bubble-check-side-stage
/tmp/bubble-check-side-stage

swiftc -parse-as-library Sources/Bubble/SessionReloadPolicy.swift scripts/check_session_reload.swift -o /tmp/bubble-check-session-reload
/tmp/bubble-check-session-reload

swiftc -parse-as-library Sources/Bubble/TranscriptInteractionPolicy.swift scripts/check_transcript_interactions.swift -o /tmp/bubble-check-transcript-interactions
/tmp/bubble-check-transcript-interactions

swiftc -parse-as-library Sources/Bubble/TranscriptSurface.swift scripts/check_transcript_surface.swift -o /tmp/bubble-check-transcript-surface
/tmp/bubble-check-transcript-surface

swiftc -parse-as-library -framework AppKit \
  Sources/Bubble/TranscriptInteractionPolicy.swift \
  Sources/Bubble/TranscriptSurface.swift \
  Sources/Bubble/AppKitTranscriptSurface.swift \
  scripts/check_appkit_transcript_surface.swift \
  -o /tmp/bubble-check-appkit-transcript-surface
/tmp/bubble-check-appkit-transcript-surface

swiftc -parse-as-library Sources/Bubble/AssistantMessageContent.swift scripts/check_assistant_message_images.swift -o /tmp/bubble-check-assistant-images
/tmp/bubble-check-assistant-images

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

swiftc -parse-as-library Sources/Bubble/BubbleNativeAction.swift scripts/check_bubble_native_actions.swift -o /tmp/bubble-check-native-actions
/tmp/bubble-check-native-actions

swift run DiagramChecks

swift run SessionTabsChecks

swiftc -parse-as-library Sources/Bubble/MessageDelivery.swift scripts/check_message_delivery.swift -o /tmp/bubble-check-message-delivery
/tmp/bubble-check-message-delivery

swiftc -parse-as-library Sources/BubbleSessions/SessionLoops.swift scripts/check_session_loops.swift -o /tmp/bubble-check-session-loops
/tmp/bubble-check-session-loops

swiftc -parse-as-library Sources/Bubble/RecordPolicy.swift scripts/check_record_policy.swift -o /tmp/bubble-check-record-policy
/tmp/bubble-check-record-policy

swiftc -parse-as-library -framework AVFoundation \
  Sources/Bubble/RecordAudioConvert.swift \
  scripts/check_record_audio.swift \
  -o /tmp/bubble-check-record-audio
/tmp/bubble-check-record-audio

swiftc -parse-as-library -lz \
  Sources/Bubble/RecordPolicy.swift \
  Sources/Bubble/RecordSeedAsrCodec.swift \
  Sources/Bubble/RecordSeedAsrCredentialsStore.swift \
  scripts/check_record_seed_asr.swift \
  -o /tmp/bubble-check-record-seed-asr
/tmp/bubble-check-record-seed-asr

python3 - <<'PY'
from pathlib import Path

src = Path("Sources/Bubble/RecordCapture.swift").read_text()
auth = Path("Sources/Bubble/RecordAudioCaptureAuthorization.swift").read_text()
plist = Path("Resources/Info.plist").read_text()
for token in ("ScreenCaptureKit", "SCContentFilter", "SCStream", "SCShareableContent"):
    if token in src:
        raise SystemExit(
            f"FAIL: RecordCapture must not use {token}; Record captures system audio via Core Audio taps"
        )
for token in ("AudioHardwareCreateProcessTap", "CATapDescription", "stereoGlobalTapButExcludeProcesses"):
    if token not in src:
        raise SystemExit(f"FAIL: RecordCapture must create a Core Audio process tap ({token})")
if "kTCCServiceAudioCapture" not in auth:
    raise SystemExit("FAIL: Record must request kTCCServiceAudioCapture; Screen Recording TCC leaves the tap silent")
if "NSAudioCaptureUsageDescription" not in plist:
    raise SystemExit("FAIL: Info.plist needs NSAudioCaptureUsageDescription for system-audio-only TCC")
print("record capture path checks passed")
PY

swiftc -parse-as-library \
  Sources/Bubble/RecordAudioCaptureAuthorization.swift \
  scripts/check_system_tap.swift \
  -o /tmp/bubble-check-system-tap
/tmp/bubble-check-system-tap

swiftc -parse-as-library Sources/Bubble/PreviewFiles.swift scripts/check_file_preview.swift -o /tmp/bubble-check-file-preview
/tmp/bubble-check-file-preview

swiftc -parse-as-library Sources/Bubble/CommandTapPolicy.swift scripts/check_command_tap.swift -o /tmp/bubble-check-tap
/tmp/bubble-check-tap

swiftc -parse-as-library Sources/BubbleMounts/WorkspaceMounts.swift Sources/Bubble/AssistantMessageContent.swift Sources/Bubble/ConversationTree.swift scripts/check_conversation_tree.swift -o /tmp/bubble-check-conversation-tree
/tmp/bubble-check-conversation-tree

swiftc -parse-as-library Sources/Bubble/BubblePiAcpPatch.swift scripts/check_pi_acp_patch.swift -o /tmp/bubble-check-pi-acp-patch
/tmp/bubble-check-pi-acp-patch

swiftc -parse-as-library Sources/BubbleMounts/WorkspaceMounts.swift scripts/check_workspace_mounts.swift -o /tmp/bubble-check-mounts
/tmp/bubble-check-mounts

swiftc -parse-as-library scripts/check_workspace_completion_order.swift -o /tmp/bubble-check-workspace-completion-order
/tmp/bubble-check-workspace-completion-order

swiftc -parse-as-library Sources/Bubble/BubbleSlot.swift scripts/check_bubble_slot.swift -o /tmp/bubble-check-slots
/tmp/bubble-check-slots

swiftc -parse-as-library \
  Sources/Bubble/BubbleNativeAction.swift \
  Sources/Bubble/JSONRPC.swift \
  Sources/Bubble/Paths.swift \
  Sources/Bubble/BubbleSlot.swift \
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
codesign --force --deep --sign - "$APP"

echo "Built $APP"
