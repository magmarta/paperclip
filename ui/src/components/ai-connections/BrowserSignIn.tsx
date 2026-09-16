// magmarta fork policy (g): sign in to a local provider from the browser.
//
// Upstream only offers a shell command to run on the host. This panel drives
// the same provider CLI through the server instead: open the link, paste the
// code here, done — no SSH, and no terminal that refuses to paste into the
// CLI's full-screen prompt. The terminal command stays available underneath
// for anyone who prefers it.
//
// A separate component so merges from paperclipai/paperclip stay clean.
// See .github/FORK-POLICY.md.

import { useState } from "react";
import { ExternalLink, Loader2 } from "lucide-react";
import type { AiConnectionLoginIntent } from "@paperclipai/shared";
import { aiConnectionsApi } from "@/api/ai-connections";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

type Phase = "idle" | "starting" | "awaiting_code" | "submitting" | "done";

export function BrowserSignIn({ companyId, sessionId, intent, providerName, onSignedIn }: {
  companyId: string | null;
  sessionId: string | undefined;
  intent: AiConnectionLoginIntent;
  providerName: string;
  onSignedIn?: () => void;
}) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [url, setUrl] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);

  if (!companyId || !sessionId) return null;

  function message(err: unknown) {
    return err instanceof Error && err.message ? err.message : "Something went wrong. Try again.";
  }

  async function start() {
    setError(null);
    setPhase("starting");
    try {
      const result = await aiConnectionsApi.spawnBrowserLogin(companyId!, sessionId!, intent);
      setUrl(result.url);
      setPhase("awaiting_code");
    } catch (err) {
      setError(message(err));
      setPhase("idle");
    }
  }

  async function submit() {
    if (!code.trim()) return;
    setError(null);
    setPhase("submitting");
    try {
      const result = await aiConnectionsApi.submitBrowserLoginCode(companyId!, sessionId!, { ...intent, code });
      if (result.ok) {
        setPhase("done");
        onSignedIn?.();
      } else {
        // The CLI rejects a stale or mistyped code without failing the request.
        setError(result.detail || `${providerName} did not accept that code. Start again to get a fresh link.`);
        setPhase("awaiting_code");
      }
    } catch (err) {
      setError(message(err));
      setPhase("awaiting_code");
    }
  }

  return (
    <div className="min-w-0 max-w-full space-y-3 rounded-md border bg-card p-3">
      <p className="text-sm font-medium text-foreground">Sign in from this browser</p>

      {phase === "idle" && (
        <>
          <p className="text-sm text-muted-foreground">
            Paperclip runs {providerName} on the server for you. No terminal needed.
          </p>
          <Button type="button" size="sm" onClick={() => void start()}>Start sign-in</Button>
        </>
      )}

      {phase === "starting" && (
        <p role="status" className="flex items-center gap-2 text-sm text-muted-foreground">
          <Loader2 className="size-4 animate-spin" />
          Starting {providerName}…
        </p>
      )}

      {(phase === "awaiting_code" || phase === "submitting") && url && (
        <>
          <ol className="list-decimal space-y-2 pl-5 text-sm text-muted-foreground">
            <li>
              <a
                href={url}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 underline underline-offset-4"
              >
                Open the {providerName} sign-in page
                <ExternalLink className="size-3.5 shrink-0" />
              </a>
            </li>
            <li>Authorize, then copy the code it gives you.</li>
            <li>Paste it here:</li>
          </ol>
          <div className="flex min-w-0 items-center gap-2">
            <Input
              value={code}
              onChange={(event) => setCode(event.target.value)}
              onKeyDown={(event) => { if (event.key === "Enter") void submit(); }}
              placeholder="Paste the code"
              aria-label="Authorization code"
              autoComplete="off"
              spellCheck={false}
              disabled={phase === "submitting"}
              className="min-w-0 flex-1 font-mono text-xs"
            />
            <Button
              type="button"
              size="sm"
              onClick={() => void submit()}
              disabled={phase === "submitting" || !code.trim()}
            >
              {phase === "submitting" ? <Loader2 className="size-4 animate-spin" /> : "Verify"}
            </Button>
          </div>
        </>
      )}

      {phase === "done" && (
        <p role="status" className="text-sm text-foreground">
          Signed in. Click Connect to use this account.
        </p>
      )}

      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    </div>
  );
}
