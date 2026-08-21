# Bubble

A macOS overlay agent. The user talks to Bubble; Pi coding-agent is the harness.

## Language

**Bubble**:
The product agent. Persona lives in `~/.bubble/AGENTS.md`. The user always addresses Bubble, never a workspace agent.
_Avoid_: overlay (the window is the face, not the agent), Pi (the harness)

**Main session**:
Bubble's long-lived ACP session. cwd is always `~/.bubble/workspace`.
_Avoid_: parent agent, root agent

**Mount**:
A durable address-book entry for a local folder (absolute path as id, folder name as display). Mounting does not start a session or load that folder's `AGENTS.md` into Bubble.
_Avoid_: workspace (ambiguous with Bubble's default cwd), project, volume

**Workspace session**:
The reused ACP child session for one mount. cwd is the mount path; that folder's `AGENTS.md` and skills load here. Created on first run, not at mount time.
_Avoid_: subagent (not a Pi subagent package), worker

**Brief**:
The only workspace state that may enter the main session. A small replaceable record: path, name, status, goal, summary, optional question, capped changed paths. No diffs, file bodies, or tool logs.
_Avoid_: summary (too vague), transcript

**Workspace run**:
The one in-flight child turn. Many mounts may exist; at most one run is active.
_Avoid_: job, task queue
