# Fork policy — magmarta/paperclip

This fork exists to run Paperclip on private infrastructure with **no
first-party outbound traffic**. Five upstream data paths are disabled in source
so the guarantee survives redeploys, environment mistakes and upstream merges.
Environment variables alone were not considered sufficient: a missing variable
on one host would silently restore the upstream behaviour.

Every patch is marked with a `magmarta fork policy (x)` comment. Where the
upstream code below the patch still type-checks as dead code it is left in
place, so merges from `paperclipai/paperclip` stay small and reviewable. For
**(b)** and **(e)** the upstream body had to be removed instead: TypeScript
stops narrowing types in unreachable code, and the leftover statements failed
to compile.

## Disabled paths

| | Path | Upstream destination | Where it is disabled |
|---|---|---|---|
| **a** | First-party telemetry | `telemetry.paperclip.ing/ingest`, AWS API Gateway fallback | `packages/shared/src/telemetry/config.ts` (`resolveTelemetryConfig`), plus `telemetryEnabled: false` in `server/src/config.ts` |
| **b** | Feedback trace sharing | `telemetry.paperclip.ing/feedback-traces` | `server/src/index.ts` (no `shareClient` wired) and `server/src/services/feedback-share-client.ts` (`uploadTraceBundle` refuses) |
| **c** | Announcement feed | `pages.paperclip.ing/announcements/v1/current.json` | `server/src/config.ts` (`announcementsEnabled: false`) |
| **d** | Sentry error reporting | Sentry ingest for the configured DSN | `server/src/sentry-dsn.ts` (`resolveSentryDsns`) |
| **e** | Paperclip Cloud connector | `my.paperclip.app` | `server/src/services/paperclip-cloud-connector.ts` (`paperclipCloudConnectorConfigFromEnv`) |

One patch is not a privacy change but an operability one:

| | Change | Where |
|---|---|---|
| **f** | `*.suffix` wildcards in `PAPERCLIP_ALLOWED_HOSTNAMES` | `server/src/middleware/private-hostname-guard.ts` |
| **g** | Browser-driven local model sign-in | `server/src/services/browser-ai-login.ts`, `ui/src/components/ai-connections/BrowserSignIn.tsx` (+ small hooks into `server/src/routes/ai-connections.ts`, `ui/src/api/ai-connections.ts`, `ui/src/components/ai-connections/useLocalAiLogin.ts`, `ui/src/components/AdapterLoginChrome.tsx`) |

Notes on each:

- **(a)** Upstream telemetry defaults to **on** (opt-out). The payload is a
  random install id, a version and enum/counter dimensions — no prompts, code
  or file contents. It is disabled here regardless, and the shared resolver
  covers both the server and the CLI.
- **(b)** This is the only upstream path that can carry real work content: an
  issue trace bundle, gzipped and uploaded. Upstream gates it behind a
  `feedbackDataSharingPreference` that defaults to `prompt`, so a user has to
  agree. In this fork the upload is removed entirely — traces stay in the local
  database with status `local_only`/`failed` and nothing is sent.
- **(c)** A periodic `GET` with no request body. It sends no data, but it does
  reveal the instance's public IP and existence to the feed host.
- **(d)** Upstream ships **no** hardcoded DSN; reporting only activates when
  `SENTRY_DSN*` is set. Forced off so a stray environment variable cannot turn
  it on.
- **(e)** Already inert unless the instance is enrolled with Paperclip Cloud.
  Forced off so enrollment cannot happen by accident.

### (f) Wildcard hostnames

Upstream requires every hostname to be listed exactly. Internal DNS here hands
out a name per site, so each new host meant editing an allow-list that nobody
remembered to edit — and the failure mode is a bare `403 This hostname is not
allowed`, which reads like an outage.

A `*.suffix` entry now admits subdomains of that suffix. The match compares the
leading dot as part of the suffix, so `*.c-prot.local` accepts
`a.b.c-prot.local` but rejects both the apex `c-prot.local` and a lookalike
such as `evil-c-prot.local`. Add the apex explicitly if you need it.

Better Auth already supports the same pattern in `trustedOrigins`, so
`deriveAuthTrustedOrigins` needed no change — it emits
`http(s)://*.c-prot.local[:port]` from the same list.

This does weaken a defence: the guard exists to blunt DNS-rebinding, and any
name under a wildcarded suffix now reaches the instance. It is a deliberate
trade for a private network whose DNS the operator controls. Pass
`--allowed-hostnames` to `scripts/magmarta-install.sh` to narrow or replace the
defaults (`*.c-prot.local,*.marta.tr`).

### (g) Browser sign-in for local subscriptions

Upstream's local-subscription flow prints a shell command and expects the
operator to run the provider CLI in a terminal on the host. That assumes shell
access to the server. Worse, on several SSH clients it is a dead end: the CLI's
device-code prompt is a full-screen TUI and those clients deliver neither
right-click nor Ctrl+Shift+V into it, so the code cannot be entered at all.
Operators who reached for a root shell instead left the credential files owned
by root, and the only symptom was `Internal server error`.

The CLI does not need a TTY — with stdin on a pipe it prints the authorization
URL and reads the code as a line. So the server runs it, hands the URL to the
browser, and writes the pasted code back into the child's stdin. Two endpoints
under the existing attempt (`.../attempts/:sessionId/spawn` and `/code`) carry
it, both behind the same authorization the other local endpoints use. The child
inherits the service user, so credentials land with correct ownership by
construction.

The terminal command is still shown underneath for anyone who prefers it, and
`scripts/magmarta-install.sh` still installs `paperclip-login` for hosts where
the browser cannot reach the instance.

Most of this lives in two fork-only files, so merges stay clean; the hooks into
upstream files are a few lines each.

## What is deliberately **not** disabled

Agent CLIs (`claude-code`, `codex`, `gemini-cli`, `opencode`, `kimi-code`) send
prompts and code context to their own model providers. That is the product
working as intended, not a leak, and it is the real data-flow decision to make
per company and per repository.

User-configured integrations (Slack, Telegram, Discord, Notion MCP, GitHub, S3,
…) also make outbound calls. They are inert until someone configures them.

## Keeping the fork current

`.github/workflows/sync-upstream.yml` merges `paperclipai/paperclip@master`
into this fork's `master` every day and on demand. It uses a **merge**, not a
fast-forward, because this fork carries the commits above — `gh repo sync`
would refuse, and `gh repo sync --force` would discard them.

If upstream edits one of the patched functions the merge conflicts, the
workflow fails and opens an issue. That is the intended behaviour: the conflict
is the review prompt. Resolve it by keeping the `magmarta fork policy` early
return at the top of the new upstream function.

After syncing, redeploy a server with:

```sh
bash /root/install-paperclip.sh --update
```

## Verifying the guarantee on a running instance

```sh
# No first-party host should appear in the server's outbound connections.
ss -tnp | grep -E 'paperclip\.ing|paperclip\.app'   # expect: no output
```
