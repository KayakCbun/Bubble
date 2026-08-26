# Bubble

A macOS overlay agent. The user talks to Bubble; Pi coding-agent is the harness.

## Language

**Bubble**:
The product agent. Persona lives in `~/.bubble/AGENTS.md`. The user always addresses Bubble, never a workspace agent.
_Avoid_: overlay (the window is the face, not the agent), Pi (the harness)

**Main session**:
Bubble's long-lived ACP session. cwd is always `~/.bubble/workspace`.
_Avoid_: parent agent, root agent

**Side session**:
An independent Bubble ACP runtime opened with `/side`. It has its own Pi process, conversation context, transcript, draft, Waiting/Steering queue, and workspace-control endpoint. Up to five main-plus-side sessions may be open and running concurrently.
_Avoid_: conversation branch, workspace session

**Session tab**:
The left-edge selector for an open main or side session. The strip is hidden while only one session is open; background activity and unread output belong to the tab that owns that runtime.
_Avoid_: conversation variant, branch switcher

**Conversation branch**:
An alternative path inside one main-session Pi JSONL tree. Bubble shows one active root-to-leaf path at a time and keeps sibling paths available through the inline variant switcher.
_Avoid_: session, fork

**Active path**:
The conversation branch currently rendered by Bubble and supplied to the model as context. Bubble persists the selected leaf per main session and restores it after reconnecting.

**Session fork**:
A separate Pi session file created by Pi `/fork` or `/clone`. This is not Bubble's default conversation branching behavior.

**Mount**:
A durable address-book entry for a local folder (absolute path as id, folder name as display). Mounting does not start a session or load that folder's `AGENTS.md` into Bubble.
_Avoid_: workspace (ambiguous with Bubble's default cwd), project, volume

**Workspace session**:
The ACP child session for one mount within one main session. cwd is the mount path; that folder's `AGENTS.md` and skills load here. Created on first run, reused only inside that main session, and recreated after Bubble starts a new main session.
_Avoid_: subagent (not a Pi subagent package), worker

**Brief**:
The only workspace state that may enter the main session. A small replaceable record: path, name, status, goal, summary, optional question, capped changed paths. No diffs, file bodies, or tool logs.
_Avoid_: summary (too vague), transcript

**Workspace run**:
The one in-flight child turn. Many mounts may exist; at most one run is active.
_Avoid_: job, task queue

**Run card**:
The main-transcript object for one workspace run. It displays the brief. Opening it reveals only that run's anchored turn and output in the workspace session.
_Avoid_: subagent card, nested tool group

Main sessions persist in `~/.bubble/session-id`. Conversation branch selections persist separately per session so a read-only branch switch survives relaunch.
