import AppKit
import Foundation

struct AgentModel: Identifiable, Equatable, Hashable {
    var provider: String
    var id: String
    var name: String

    var identity: String {
        provider.isEmpty ? id : "\(provider)/\(id)"
    }

    var displayName: String {
        if name.isEmpty || name == id || name == identity { return identity }
        if name.contains("/") { return name }
        return provider.isEmpty ? name : "\(provider)/\(name)"
    }

    static func parse(_ identity: String, name: String? = nil) -> AgentModel {
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.firstIndex(of: "/") {
            let provider = String(trimmed[..<slash])
            let id = String(trimmed[trimmed.index(after: slash)...])
            let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentModel(
                provider: provider,
                id: id,
                name: (resolvedName?.isEmpty == false ? resolvedName! : id)
            )
        }
        return AgentModel(provider: "", id: trimmed, name: name ?? trimmed)
    }
}

struct BubbleSettings: Codable, Equatable {
    var provider: String?
    var model: String?
    var thinking: String?

    var modelIdentity: String? {
        guard let model, !model.isEmpty else { return nil }
        if model.contains("/") { return model }
        if let provider, !provider.isEmpty {
            return "\(provider)/\(model)"
        }
        return model
    }

    mutating func setModel(identity: String) {
        if let slash = identity.firstIndex(of: "/") {
            provider = String(identity[..<slash])
            model = String(identity[identity.index(after: slash)...])
        } else {
            provider = nil
            model = identity
        }
    }
}

enum BubbleConfig {
    static let defaultThinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]

    static let macSection = """
    ## Mac

    Bubble is a native macOS overlay. The user can attach the live clipboard with `@clipboard` or `/clipboard`, and launch installed apps with `/open Safari`.

    During a turn you can also use bash:
    - `pbpaste` to read clipboard text
    - `open -a "Safari"` to launch an app by name
    - `open /path` to open a file or folder in Finder
    """

    static let workspaceSection = """
    ## Mounted workspaces

    The user can mount other local folders (`/mounts`). A mount is an address book entry, not a change of persona.

    For work that belongs in a mounted folder, call `workspace_run` with the mount name or path. That includes using that folder's skills, code, or docs. You do not have those skills in this session. The per-turn status block lists their names. If the ask matches a listed skill or that repo, call workspace_run immediately. Do not reconstruct the skill with bash.

    After starting a run, do not repeat yourself. Wait for the brief.

    Do not treat a mounted folder's AGENTS.md as your own instructions.
    If a workspace run is already in progress and the user asks about a different mount, ask whether to wait, cancel the current run, or note the new work for later.
    To stop a run, call `workspace_cancel`.
    You may also `mount_workspace` / `unmount_workspace`. Unmounting a running workspace is refused.
    """

    static let voiceSection = """
    ## Voice

    Unslop is always on. You are a sharp coworker, not a chatbot.

    Lead with the answer. Have opinions. Mix short sentences with longer ones that earn their keep. Use I when you did the work. Match the user's language.

    Do not use em dashes. Periods and commas only. No chatbot padding: no "Of course!", "Great question!", "I hope this helps", "Let me know if". Cut puffery: pivotal, landscape, delve, leverage, utilize, showcase, testament. Say is, has, use. If a sentence could sit in any product's docs unchanged, cut it.

    The full unslop checklist is the `unslop` skill. Apply it to everything you write, not only when the user names it.
    """

    static let skillsSection = """
    ## Skills

    When the user asks to add a skill, install it for Bubble, not for a mounted repo and not for the Pi TUI, unless they say otherwise.

    Bubble skills live in `~/.bubble/workspace/.pi/skills/<name>/SKILL.md`. That folder is this agent. `~/.pi/agent/skills/` also shows up in the Pi TUI. `~/.agents/skills/` is shared with other agents on this machine.

    A skill is a directory with a `SKILL.md`. Frontmatter needs `name` and `description`. Put "Use when..." in the description so you actually pick it up.

    To add one: create that directory, write `SKILL.md`, then `/reload` or tell them to type `$` and look for the name. If they give a GitHub URL, copy that skill folder here. Do not drop it into a mounted workspace unless they asked for that repo.

    Built-in for you: `unslop`.
    """

    static let piSection = """
    ## Pi

    You run on Pi coding-agent through `pi-acp`. cwd is `~/.bubble/workspace`. Credentials and the model catalog live in `~/.pi/agent/`. Bubble's model and thinking live in `~/.bubble/config.json`. Do not rewrite Pi TUI settings to change your model. Use `/model` and `/thinking`.

    If Pi is missing: `curl -fsSL https://pi.dev/install.sh | sh`. If `pi-acp` is missing: `npm install -g pi-acp` (Node 22+). If the model list is empty, nobody is signed in. Use `/login` or run `pi` in Terminal.

    Skills or the workspace extension not loading usually means this workspace is untrusted. `~/.pi/agent/trust.json` must include `~/.bubble/workspace`. Logs are `~/.bubble/overlay.log`.

    Overlay-local commands: `/clear`, `/new`, `/model`, `/thinking`, `/agents`, `/open`, `/mounts`, `/clipboard`, `/quit`. `/skill:name`, `/compact`, and the rest go to Pi.
    """

    static let defaultAgentsMarkdown = """
    # Bubble

    You are Bubble, a macOS overlay agent. The user talks to you in a floating panel. You are not the Pi TUI, and you are not whatever folder they mounted.

    This workspace (`~/.bubble/workspace`) is a scratch pad. Keep answers short. Do not create files unless asked. Prefer answering in place over running tools, except when a mounted workspace can do the job. Then call workspace_run.

    \(voiceSection)

    \(macSection)

    \(workspaceSection)

    \(skillsSection)

    \(piSection)
    """

    static func load() -> BubbleSettings {
        guard let data = try? Data(contentsOf: OverlayPaths.configFile),
              let settings = try? JSONDecoder().decode(BubbleSettings.self, from: data) else {
            return BubbleSettings()
        }
        return settings
    }

    static func save(_ settings: BubbleSettings) {
        OverlayPaths.bootstrap()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: OverlayPaths.configFile, options: .atomic)
    }

    static func update(_ mutate: (inout BubbleSettings) -> Void) {
        var settings = load()
        mutate(&settings)
        save(settings)
    }

    static func ensureAgentsFile() {
        let fm = FileManager.default
        let canonical = OverlayPaths.agentsFile
        let linked = OverlayPaths.workspaceAgentsFile

        if !fm.fileExists(atPath: canonical.path) {
            if let existing = migratedWorkspaceAgents() {
                try? existing.write(to: canonical, atomically: true, encoding: .utf8)
            } else {
                try? defaultAgentsMarkdown.write(to: canonical, atomically: true, encoding: .utf8)
            }
        }

        let destination = canonical.path
        if let current = try? fm.destinationOfSymbolicLink(atPath: linked.path), current == destination {
            ensureAgentSections()
            return
        }
        if fm.fileExists(atPath: linked.path) || (try? fm.destinationOfSymbolicLink(atPath: linked.path)) != nil {
            try? fm.removeItem(at: linked)
        }
        try? fm.createSymbolicLink(atPath: linked.path, withDestinationPath: destination)
        ensureAgentSections()
    }

    static func ensureAgentSections() {
        ensureMacSection()
        ensureWorkspaceSection()
        ensureNamedSection(heading: "## Voice", contains: "Unslop is always on", body: voiceSection)
        ensureNamedSection(heading: "## Skills", contains: "workspace/.pi/skills", body: skillsSection)
        ensureNamedSection(heading: "## Pi", contains: "You run on Pi", body: piSection)
    }

    static func ensureNamedSection(heading: String, contains needle: String, body: String) {
        let url = OverlayPaths.agentsFile
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if text.contains(heading) || text.contains(needle) {
            return
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + body + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func ensureMacSection() {
        let url = OverlayPaths.agentsFile
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if text.contains("## Mac") || text.contains("/open") || text.contains("@clipboard") {
            return
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + macSection + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func ensureWorkspaceSection() {
        let url = OverlayPaths.agentsFile
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if text.contains("## Mounted workspaces") || text.contains("workspace_run") {
            return
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + workspaceSection + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func ensureWorkspaceExtension() {
        let url = OverlayPaths.workspaceExtensionFile
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? workspaceExtensionSource.write(to: url, atomically: true, encoding: .utf8)
    }

    static func ensureUnslopSkill() {
        let dir = OverlayPaths.workspaceSkillsDirectory.appendingPathComponent("unslop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? unslopSkillSource.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    static func ensureWorkspaceTrust() {
        let url = OverlayPaths.piAgent.appendingPathComponent("trust.json")
        var map: [String: Bool] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in parsed {
                if value as? Bool == true || (value as? NSNumber)?.boolValue == true {
                    map[key] = true
                }
            }
        }
        let path = OverlayPaths.workspace.path
        if map[path] == true { return }
        map[path] = true
        guard JSONSerialization.isValidJSONObject(map),
              let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? FileManager.default.createDirectory(at: OverlayPaths.piAgent, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static let workspaceExtensionSource = #"""
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

let steeringServer: net.Server | undefined;
let steeringControlFile: string | undefined;
let steeringToken = "";
let steeringBusy = false;
let steeringGeneration = 0;

function removeSteeringControl() {
  if (!steeringControlFile) return;
  try { fs.unlinkSync(steeringControlFile); } catch {}
}

function sessionIdFromFile(file: string | undefined): string | undefined {
  if (!file) return undefined;
  const match = path.basename(file).match(/_([^_]+)\.jsonl$/);
  return match?.[1];
}

function publishSteeringControl() {
  const address = steeringServer?.address();
  if (!steeringBusy || !steeringControlFile || !address || typeof address === "string") return;
  fs.writeFileSync(
    steeringControlFile,
    JSON.stringify({ port: address.port, token: steeringToken, generation: steeringGeneration }),
    { mode: 0o600 },
  );
}

function startSteeringControl(pi: ExtensionAPI, sessionFile: string | undefined) {
  const sessionId = sessionIdFromFile(sessionFile);
  if (!sessionId) return;
  removeSteeringControl();
  const directory = path.join(os.homedir(), ".bubble", "steering");
  fs.mkdirSync(directory, { recursive: true });
  steeringControlFile = path.join(directory, `${sessionId}.json`);

  if (!steeringServer) {
    steeringServer = net.createServer((socket) => {
      let buffer = "";
      socket.setTimeout(5000);
      socket.on("timeout", () => socket.destroy());
      socket.on("data", (chunk) => {
        buffer += chunk.toString("utf8");
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        try {
          const request = JSON.parse(buffer.slice(0, newline)) as {
            token?: string;
            generation?: number;
            text?: string;
            images?: Array<{ mimeType?: string; data?: string }>;
          };
          if (request.token !== steeringToken || request.generation !== steeringGeneration) {
            throw new Error("steer-stale");
          }
          if (!steeringBusy) throw new Error("steer-unavailable");
          const text = String(request.text ?? "").trim();
          const images = (request.images ?? [])
            .filter((image) => image.mimeType && image.data)
            .map((image) => ({
              type: "image" as const,
              source: {
                type: "base64" as const,
                mediaType: image.mimeType!,
                data: image.data!,
              },
            }));
          if (!text && images.length === 0) throw new Error("empty steering message");
          const content = images.length === 0
            ? text
            : [{ type: "text" as const, text }, ...images];
          pi.sendUserMessage(content, { deliverAs: "steer" });
          socket.end(JSON.stringify({ ok: true }) + "\n");
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          socket.end(JSON.stringify({ ok: false, error: message }) + "\n");
        }
      });
    });
    steeringServer.listen(0, "127.0.0.1", () => {
      publishSteeringControl();
    });
  } else {
    publishSteeringControl();
  }
}

function controlConfig() {
  const file = path.join(os.homedir(), ".bubble", "control.json");
  const raw = fs.readFileSync(file, "utf8");
  return JSON.parse(raw) as { port: number; token: string };
}

function call(method: string, params: Record<string, unknown>): Promise<unknown> {
  const cfg = controlConfig();
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port: cfg.port });
    let buf = "";
    const finish = (err: Error | null, value?: unknown) => {
      socket.end();
      if (err) reject(err);
      else resolve(value);
    };
    socket.setTimeout(30000);
    socket.on("timeout", () => finish(new Error("workspace control timed out")));
    socket.on("error", (err) => finish(err));
    socket.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      const idx = buf.indexOf("\n");
      if (idx < 0) return;
      try {
        const msg = JSON.parse(buf.slice(0, idx)) as { ok?: boolean; result?: unknown; error?: string };
        if (msg.ok) finish(null, msg.result ?? {});
        else finish(new Error(msg.error || "workspace control error"));
      } catch (err) {
        finish(err instanceof Error ? err : new Error(String(err)));
      }
    });
    socket.write(JSON.stringify({ token: cfg.token, method, params }) + "\n");
  });
}

async function textResult(method: string, params: Record<string, unknown>) {
  const result = await call(method, params);
  return {
    content: [{ type: "text" as const, text: JSON.stringify(result) }],
  };
}

export default function (pi: ExtensionAPI) {

  pi.on("session_start", (_event, ctx) => {
    startSteeringControl(pi, ctx.sessionManager.getSessionFile());
  });
  pi.on("agent_start", () => {
    steeringBusy = true;
    steeringGeneration += 1;
    steeringToken = crypto.randomUUID();
    publishSteeringControl();
  });
  pi.on("agent_settled", () => {
    steeringBusy = false;
    steeringToken = crypto.randomUUID();
    removeSteeringControl();
  });
  pi.on("session_shutdown", () => {
    steeringBusy = false;
    removeSteeringControl();
    steeringControlFile = undefined;
    steeringServer?.close();
    steeringServer = undefined;
  });

  pi.registerTool({
    name: "workspace_run",
    label: "Workspace Run",
    description: "Dispatch a task into a mounted workspace child session. Use this instead of bash whenever the work belongs in a mounted folder. That folder's skills only exist in the child. `mount` is the folder name or path.",
    promptSnippet: "Dispatch work into a mounted workspace",
    promptGuidelines: [
      "Use workspace_run when the user wants substantive work inside a mounted workspace.",
      "Do not load a mounted workspace AGENTS.md as your own instructions.",
      "If another workspace is already running, ask the user whether to wait, cancel, or note it down.",
      "After workspace_run returns started, do not send more user-facing text in this turn. Progress belongs on the workspace card; speak again only when the workspace reports a result.",
    ],
    parameters: Type.Object({
      mount: Type.String({ description: "Mount name or absolute path" }),
      prompt: Type.String({ description: "Task for the workspace agent" }),
    }),
    async execute(_id, params) {
      return textResult("workspace_run", params as Record<string, unknown>);
    },
  });

  pi.registerTool({
    name: "workspace_cancel",
    label: "Workspace Cancel",
    description: "Cancel the in-flight mounted workspace run.",
    parameters: Type.Object({}),
    async execute() {
      return textResult("workspace_cancel", {});
    },
  });

  pi.registerTool({
    name: "mount_workspace",
    label: "Mount Workspace",
    description: "Mount a local folder so it can be used with workspace_run.",
    parameters: Type.Object({
      path: Type.String({ description: "Absolute path or ~/ path" }),
    }),
    async execute(_id, params) {
      return textResult("mount_workspace", params as Record<string, unknown>);
    },
  });

  pi.registerTool({
    name: "unmount_workspace",
    label: "Unmount Workspace",
    description: "Remove a folder from the mount list. Refused while that workspace is running.",
    parameters: Type.Object({
      path: Type.String({ description: "Mount name or path" }),
    }),
    async execute(_id, params) {
      return textResult("unmount_workspace", params as Record<string, unknown>);
    },
  });
}
"""#

    static let unslopSkillSource = #"""
---
name: unslop
description: Cut AI tells from any writing. Must always apply. Use when writing, editing, or reviewing prose.
---

# Unslop

Edit text to remove AI patterns and add human voice.

## Process

1. Scan for the patterns below.
2. Rewrite. Preserve meaning, match intended tone.
3. Add soul (see next section).
4. Self-audit: "What makes this obviously AI generated?" Fix remaining tells.

## Adding soul

Removing patterns is half the job. Sterile, voiceless writing is just as obvious.

- **Have opinions.** React to facts instead of neutrally listing pros and cons.
- **Vary rhythm.** Short sentences. Then longer ones that take their time. Mix it up.
- **Acknowledge complexity.** "Impressive but also kind of unsettling" beats "impressive."
- **Use "I" when it fits.** First person isn't unprofessional.
- **Let some mess in.** Perfect structure looks machine-made.
- **Be specific.** Not "this is concerning" but "there's something unsettling about agents churning away at 3am."

## Patterns to detect and fix

### Content

1. **Puffery.** "pivotal moment", "testament to", "evolving landscape", "setting the stage for", "indelible mark", "deeply rooted". Cut puffery, state what happened.
2. **Name-dropping.** Listing media outlets without context. Pick one, say what was said.
3. **Superficial -ing phrases.** "highlighting...", "ensuring...", "reflecting...", "showcasing...", "fostering...". Delete or expand with real sources.
4. **Promotional language.** "nestled", "vibrant", "breathtaking", "groundbreaking", "renowned", "stunning", "must-visit". Use neutral descriptions.
5. **Vague attributions.** "Experts believe", "Industry reports suggest", "Some critics argue". Name the source or delete.
6. **Formulaic challenges.** "Despite challenges... continues to thrive." Replace with specific facts.

### Language

7. **AI vocabulary.** Additionally, crucial, delve, enduring, enhance, fostering, garner, interplay, intricate, landscape (abstract), pivotal, showcase, tapestry (abstract), testament, underscore, vibrant. Replace with plain words.
8. **Fancy ways to say "is".** "serves as", "stands as", "boasts", "features". Just say "is" or "has".
9. **"Not just X, but Y."** State the point directly instead.
10. **Rule of three.** Forcing ideas into groups of three. Use the natural number.
11. **Synonym cycling.** Protagonist, main character, central figure, hero all in one paragraph. Pick one, repeat it.
12. **False ranges.** "from X to Y" where X and Y aren't on a meaningful scale. List topics directly.

### Style

13. **Em dash overuse.** Avoid em dashes entirely. Use periods or commas only. If a thought needs separation, end the sentence or use a comma.
14. **Colon overuse.** Colons are fine before a list or example. Not as mid-sentence connectors.
15. **Boldface overuse.** Don't bold every proper noun or acronym.
16. **Inline-header lists.** The tell is a bold label and colon that restates the line. Convert those to prose.
17. **Title case headings.** Use sentence case.
18. **Decorative emojis.** Remove from headings and bullets.
19. **Curly quotes.** Replace with straight quotes.

### Communication artifacts

20. **Chatbot phrases.** "I hope this helps!", "Let me know if...", "Of course!", "Certainly!", "Found the smoking gun!" Remove.
21. **Cutoff disclaimers.** "While specific details are limited..." Find sources or remove.
22. **Sycophantic tone.** "Great question! You're absolutely right!" Respond directly.

### Filler

23. **Filler phrases.** "In order to" becomes "To". "Due to the fact that" becomes "Because". "It is important to note that" gets deleted.
24. **Excessive hedging.** "could potentially possibly be argued that it might" becomes "may".
25. **Generic conclusions.** "The future looks bright." State specific plans or facts.

### Jargon

26. **Abstract metaphor nouns.** Substrate, wedge, vector, locus, vantage, nexus, primitive (as noun), harness (as metaphor), surface (as in "API surface"), bedrock, scaffolding (as metaphor), modality, paradigm, gold-plating, ratchet (as metaphor), evacuate (for moving code), endgame, north star, flywheel. Pick the concrete word.

### Plain speech

27. **Say what it does, not how it feels.** Name the mechanism or a number. If a sentence could appear unchanged in another project's docs, cut it.
28. **Shorten or split dense sentences.** One idea per sentence.
29. **Active voice.** Prefer it. Name the actor.
30. **Cut adverbs, or use a stronger verb.**
31. **Prefer the plain word.** "utilize" becomes "use", "leverage" becomes "use", "facilitate" becomes "help".
"""#

    static func openAgentsFile() {
        OverlayPaths.bootstrap()
        ensureAgentsFile()
        NSWorkspace.shared.open(OverlayPaths.agentsFile)
    }

    static func catalogModels() -> [AgentModel] {
        var models: [AgentModel] = []
        var seen = Set<String>()
        func add(_ incoming: [AgentModel]) {
            for model in incoming where seen.insert(model.identity).inserted {
                models.append(model)
            }
        }
        add(modelsFromStore(OverlayPaths.piAgent.appendingPathComponent("models-store.json")))
        add(modelsFromCustom(OverlayPaths.piAgent.appendingPathComponent("models.json")))
        return models.sorted { $0.identity < $1.identity }
    }

    private static func migratedWorkspaceAgents() -> String? {
        let url = OverlayPaths.workspaceAgentsFile
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return nil
        }
        guard fm.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func modelsFromStore(_ url: URL) -> [AgentModel] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var models: [AgentModel] = []
        for (provider, value) in json {
            let object = JSONValue.object(value) ?? [:]
            let raw = object.array("models") ?? []
            for entry in raw {
                guard let model = JSONValue.object(entry),
                      let id = model.string("id"), !id.isEmpty else { continue }
                let name = model.string("name") ?? id
                let resolved = model.string("provider") ?? provider
                models.append(AgentModel(provider: resolved, id: id, name: name))
            }
        }
        return models
    }

    private static func modelsFromCustom(_ url: URL) -> [AgentModel] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let providers = json.dictionary("providers") ?? [:]
        var models: [AgentModel] = []
        for (provider, value) in providers {
            let object = JSONValue.object(value) ?? [:]
            let raw = object.array("models") ?? []
            for entry in raw {
                guard let model = JSONValue.object(entry),
                      let id = model.string("id"), !id.isEmpty else { continue }
                models.append(AgentModel(provider: provider, id: id, name: model.string("name") ?? id))
            }
        }
        return models
    }
}

enum BubbleComposer {
    static let stagedCommands = ["model", "thinking", "open", "mounts", "login", "logout", "resume", "tree"]

    static func argumentQuery(command: String, in draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/\(command)"
        if trimmed == prefix { return "" }
        let spaced = prefix + " "
        if trimmed.hasPrefix(spaced) {
            return String(trimmed.dropFirst(spaced.count))
        }
        return nil
    }

    static func isStaged(_ draft: String) -> Bool {
        stagedCommands.contains { argumentQuery(command: $0, in: draft) != nil }
    }
}

extension Notification.Name {
    static let bubbleSessionConfigDidChange = Notification.Name("bubble.sessionConfigDidChange")
}
