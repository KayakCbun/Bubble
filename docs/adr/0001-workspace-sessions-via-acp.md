# Workspace runs are extra ACP sessions, not Pi subagents

Bubble orchestrates mounted folders by opening a second ACP session (`session/new` with that cwd) on the same `pi-acp` process. Dispatch tools are a Bubble-owned Pi extension in `~/.bubble/workspace/.pi/extensions/`. We rejected Pi subagent packages (they dump child traces into the main transcript and are optional) and ACP `mcpServers` (pi-acp accepts them but does not wire them through).
