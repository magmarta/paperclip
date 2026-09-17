// magmarta fork policy (g): browser-driven local model sign-in.
//
// Upstream's local-subscription flow hands the operator a shell command and
// expects them to run the provider CLI in a terminal on the host. That assumes
// shell access to the server, and on several SSH clients it is a dead end
// anyway: the CLI's device-code prompt is a full-screen TUI, and those clients
// deliver neither right-click nor Ctrl+Shift+V into it, so the code cannot be
// entered at all. Operators who reached for a root shell instead left the
// credential files owned by root, which broke the flow in a way whose only
// symptom was "Internal server error".
//
// The CLI does not need a TTY: with stdin on a pipe it prints the
// authorization URL and then reads the code as a line. So the server runs it
// itself, hands the URL to the browser, and writes the pasted code back into
// the child's stdin. The child inherits the service user, so credentials land
// with the right ownership by construction.
//
// Deliberately a separate module: it adds no behaviour to upstream files, so
// merges from paperclipai/paperclip stay clean. See .github/FORK-POLICY.md.

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import path from "node:path";
import { z } from "zod";
import { localAiConnectionSchema } from "@paperclipai/shared";
import { resolvePaperclipInstanceRoot } from "../home-paths.js";
import { readVerifiedLocalAiCredential } from "./local-ai-credentials.js";
import { unprocessable } from "../errors.js";

/** Mirrors `loginHome` in local-ai-login.ts. Duplicated rather than exported
 * from there so this feature touches no upstream file. */
export function browserLoginHome(sessionId: string): string {
  return path.join(resolvePaperclipInstanceRoot(), "ai-local-logins", sessionId);
}

/** The attempt intent the other local routes already validate, plus the code
 * the operator pasted in the browser. */
export const browserLoginCodeSchema = localAiConnectionSchema.extend({
  code: z.string().trim().min(1).max(4096),
});

export type BrowserLoginProvider = "anthropic" | "openai" | "xai";

interface PendingLogin {
  child: ChildProcessWithoutNullStreams;
  /** Combined stdout+stderr. Bounded: the CLI prints a handful of lines. */
  output: string;
  url: string | null;
  exited: boolean;
  exitCode: number | null;
  startedAt: number;
  timer: ReturnType<typeof setTimeout>;
}

const pending = new Map<string, PendingLogin>();

/** An unfinished child is a process holding a pipe, so it cannot be left to
 * linger. Longer than the 30-minute attempt window would be pointless. */
const PENDING_TTL_MS = 15 * 60 * 1000;
const URL_WAIT_MS = 45_000;
const EXIT_WAIT_MS = 90_000;
const MAX_OUTPUT_BYTES = 64 * 1024;
const URL_PATTERN = /https?:\/\/[^\s"']+/;

function launchArgs(provider: BrowserLoginProvider, directory: string): {
  file: string;
  args: string[];
  env: NodeJS.ProcessEnv;
} {
  switch (provider) {
    case "anthropic":
      return { file: "claude", args: ["auth", "login"], env: { CLAUDE_CONFIG_DIR: directory } };
    case "openai":
      return {
        file: "codex",
        args: ["-c", 'cli_auth_credentials_store="file"', "login", "--device-auth"],
        env: { CODEX_HOME: directory },
      };
    case "xai":
      return { file: "grok", args: ["login", "--device-auth"], env: { GROK_HOME: directory } };
  }
}

export function cancelBrowserLogin(sessionId: string): void {
  const entry = pending.get(sessionId);
  if (!entry) return;
  pending.delete(sessionId);
  clearTimeout(entry.timer);
  if (!entry.exited) entry.child.kill("SIGTERM");
}

function reapExpired(): void {
  const now = Date.now();
  for (const [id, entry] of pending) {
    if (now - entry.startedAt > PENDING_TTL_MS) cancelBrowserLogin(id);
  }
}

/**
 * Starts the provider CLI for an attempt and resolves once it has printed its
 * authorization URL. Replaces any sign-in already running for the same attempt,
 * so a retry from the browser cannot leave an orphan holding the directory.
 */
export async function beginBrowserLogin(input: {
  sessionId: string;
  provider: BrowserLoginProvider;
}): Promise<{ url: string }> {
  reapExpired();
  cancelBrowserLogin(input.sessionId);

  const directory = browserLoginHome(input.sessionId);
  const { file, args, env } = launchArgs(input.provider, directory);

  let child: ChildProcessWithoutNullStreams;
  try {
    child = spawn(file, args, {
      cwd: directory,
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    throw unprocessable(`Could not start ${file}. Is it installed on the machine running Paperclip?`);
  }

  const entry: PendingLogin = {
    child,
    output: "",
    url: null,
    exited: false,
    exitCode: null,
    startedAt: Date.now(),
    timer: setTimeout(() => cancelBrowserLogin(input.sessionId), PENDING_TTL_MS),
  };
  pending.set(input.sessionId, entry);

  const collect = (chunk: Buffer) => {
    if (entry.output.length < MAX_OUTPUT_BYTES) entry.output += chunk.toString("utf8");
    if (!entry.url) entry.url = entry.output.match(URL_PATTERN)?.[0] ?? null;
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  child.on("exit", (code) => {
    entry.exited = true;
    entry.exitCode = code;
  });
  // A spawn failure (missing binary) surfaces here, not from spawn() itself.
  child.on("error", () => {
    entry.exited = true;
    entry.exitCode = -1;
  });

  const deadline = Date.now() + URL_WAIT_MS;
  while (Date.now() < deadline) {
    if (entry.url) return { url: entry.url };
    if (entry.exited) break;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }

  cancelBrowserLogin(input.sessionId);
  throw unprocessable(
    entry.output.trim()
      ? `${file} did not return a sign-in link: ${entry.output.trim().slice(0, 300)}`
      : `${file} did not return a sign-in link in time.`,
  );
}

/**
 * Feeds the operator's code to the waiting CLI, waits for it to finish, and
 * only reports success once a usable credential is actually on disk.
 *
 * The exit code alone is not enough. A sign-in that ends without writing
 * credentials still exits cleanly, and reporting that as success is how an
 * unusable connection gets saved: the operator sees "signed in", presses
 * Connect, and every later run dies with the provider's auth_required — which
 * surfaces far away from here, as a bare "terminal access failure" on the
 * agent run, with nothing pointing back at the sign-in.
 */
export async function submitBrowserLoginCode(input: {
  sessionId: string;
  provider: BrowserLoginProvider;
  code: string;
}): Promise<{ ok: boolean; detail: string }> {
  const entry = pending.get(input.sessionId);
  if (!entry) throw unprocessable("No sign-in is waiting for a code. Start sign-in again.");
  if (entry.exited) {
    cancelBrowserLogin(input.sessionId);
    throw unprocessable("The sign-in process already finished. Start sign-in again.");
  }

  const before = entry.output.length;
  entry.child.stdin.write(`${input.code.trim()}\n`);

  const deadline = Date.now() + EXIT_WAIT_MS;
  while (Date.now() < deadline && !entry.exited) {
    await new Promise((resolve) => setTimeout(resolve, 200));
  }

  const detail = entry.output.slice(before).trim().slice(0, 500);
  const exitedCleanly = entry.exited && entry.exitCode === 0;
  if (entry.exited) cancelBrowserLogin(input.sessionId);

  if (!exitedCleanly) {
    return {
      ok: false,
      detail: detail || "The sign-in did not complete. Start sign-in again for a fresh link.",
    };
  }

  // The same check the connect path runs, so "signed in" here and a working
  // Connect cannot disagree.
  try {
    await readVerifiedLocalAiCredential(
      input.provider === "anthropic" ? "anthropic" : input.provider === "openai" ? "openai" : "xai",
      browserLoginHome(input.sessionId),
    );
  } catch {
    return {
      ok: false,
      detail: "The sign-in finished but left no usable credential. Start sign-in again.",
    };
  }
  return { ok: true, detail };
}
