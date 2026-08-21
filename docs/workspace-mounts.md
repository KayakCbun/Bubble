# Workspace mounts

Bubble stays Bubble. A mount is an address-book entry for another local folder. Substantive work there runs in a reused ACP child session. The main session only ever sees a brief.

## Shape

- Registry: `~/.bubble/mounts.json`. Survives `/new` and relaunch. `/mounts` toggles it locally, like `/open`.
- Many mounts, one in-flight run. A second workspace request is asked wait / cancel / note — no hidden queue.
- Child session created on first `workspace_run`, then reused. Same model and thinking as Bubble.
- `/mounts` palette lists `$HOME`’s non-hidden directories, current mounts, and recently unmounted folders. Click a folder to open it; `..` and ← go up; the status icon mounts or unmounts. Browse… uses the system folder picker. `~/.bubble` is not mountable.
- A running mount cannot be silently unmounted.

## Isolation

- Main cwd stays `~/.bubble/workspace`. Child cwd is the mount path, so that folder’s `AGENTS.md` loads only there. The main prompt lists each mount’s project skill names so Bubble knows when to dispatch. It does not load those skills itself.
- Child thought/tool/diff stay inside the run card (UI only).
- Each main prompt is prefixed with a compact mount-status block the UI does not show in the user bubble.
- When the child finishes, Bubble starts a short text-only turn to tell the user the result. That turn must not call tools. If it tries, the tools are cancelled and the child's summary is posted as fallback.
- No filesystem jail: Bubble can still touch arbitrary paths, as today. Policy is: use `workspace_run` for substantive work in a mount; do not adopt that folder’s `AGENTS.md` as persona.

## Tools

Pi extension at `~/.bubble/workspace/.pi/extensions/bubble-workspace.ts`:

- `workspace_run(mount, prompt)` — start or steer; refuse if another mount is running
- `workspace_cancel()` — cancel the in-flight run
- `mount_workspace` / `unmount_workspace` — same registry as `/mounts`

The extension calls overlay over loopback JSON. Overlay owns `session/new`, streaming, the card, and injection.

## Conversation

- User → Bubble → a run card at that turn (updates in place while live) → Bubble speaks on terminal events. A later user turn that calls `workspace_run` opens a new card, even if the previous card is still marked running. The stale card is closed.
- Composer chip while a run is active (name, status, stop). Not a second input.
- Escape / click-outside hides the overlay; the run continues. Stop is explicit (chip, card, or `workspace_cancel`).
- Hide ≠ quit. Quit kills `pi-acp` and marks the run interrupted; relaunch loads the child session id and injects the interrupted brief.

## Brief

`path`, `name`, `status` (`running` | `waiting` | `done` | `failed` | `interrupted`), `goal`, `summary`, `question?`, `changed_paths` (capped).
