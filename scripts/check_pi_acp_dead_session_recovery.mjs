#!/usr/bin/env node

import { execFileSync, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import readline from "node:readline";

const bubbleRoot = join(homedir(), ".bubble");
const sessionId = readFileSync(join(bubbleRoot, "session-id"), "utf8").trim();
const cwd = join(bubbleRoot, "workspace");
const executable = join(bubbleRoot, "runtime", "node_modules", ".bin", "pi-acp");
const agent = spawn(executable, [], {
  cwd,
  env: process.env,
  stdio: ["pipe", "pipe", "pipe"],
});

let nextId = 1;
const pending = new Map();
let stderr = "";
agent.stderr.setEncoding("utf8");
agent.stderr.on("data", chunk => { stderr += chunk; });

readline.createInterface({ input: agent.stdout }).on("line", line => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.id == null) return;
  const waiter = pending.get(String(message.id));
  if (!waiter) return;
  pending.delete(String(message.id));
  clearTimeout(waiter.timer);
  if (message.error) waiter.reject(new Error(message.error.data?.details ?? message.error.message));
  else waiter.resolve(message.result);
});

function request(method, params) {
  const id = String(nextId++);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timed out waiting for ${method}`));
    }, 10_000);
    pending.set(id, { resolve, reject, timer });
    agent.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}

function directChildren(parentPid) {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid=,command="], { encoding: "utf8" });
  return rows.split("\n").flatMap(line => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (!match || Number(match[2]) !== parentPid) return [];
    return [{ pid: Number(match[1]), command: match[3] }];
  });
}

async function waitFor(predicate, message) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const value = predicate();
    if (value) return value;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error(message);
}

try {
  await request("initialize", {
    protocolVersion: 1,
    clientInfo: { name: "bubble-recovery-check", version: "1" },
    clientCapabilities: {},
  });
  await request("session/load", { sessionId, cwd, mcpServers: [] });
  const piChild = await waitFor(
    () => directChildren(agent.pid)[0],
    `pi-acp did not expose its Pi RPC child after session/load; children=${JSON.stringify(directChildren(agent.pid))}`,
  );
  process.kill(piChild.pid, "SIGTERM");
  await waitFor(
    () => !directChildren(agent.pid).some(child => child.pid === piChild.pid),
    "Pi RPC child did not exit",
  );
  await request("_bubble/session/tree", { sessionId });
  console.log("PASS: pi-acp restored a dead loaded-session RPC process");
} catch (error) {
  console.error(`FAIL: ${error.message}`);
  if (stderr.trim()) console.error(stderr.trim());
  process.exitCode = 1;
} finally {
  agent.stdin.end();
  agent.kill("SIGTERM");
}
