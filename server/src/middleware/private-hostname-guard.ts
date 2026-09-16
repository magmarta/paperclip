import type { Request, RequestHandler } from "express";

function isLoopbackHostname(hostname: string): boolean {
  const normalized = hostname.trim().toLowerCase();
  return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1";
}

function extractHostname(req: Request): string | null {
  const forwardedHost = req.header("x-forwarded-host")?.split(",")[0]?.trim();
  const hostHeader = req.header("host")?.trim();
  const raw = forwardedHost || hostHeader;
  if (!raw) return null;

  try {
    return new URL(`http://${raw}`).hostname.trim().toLowerCase();
  } catch {
    return raw.trim().toLowerCase();
  }
}

function normalizeAllowedHostnames(values: string[]): string[] {
  const unique = new Set<string>();
  for (const value of values) {
    const trimmed = value.trim().toLowerCase();
    if (!trimmed) continue;
    unique.add(trimmed);
  }
  return Array.from(unique);
}

// magmarta fork policy (f): a `*.suffix` entry in PAPERCLIP_ALLOWED_HOSTNAMES
// admits every subdomain of that suffix. Internal DNS here hands out a name per
// site (esra.kaydu.c-prot.local, ...), and re-enumerating them on every host was
// the step operators actually got wrong.
//
// The match is deliberately narrow. `*.c-prot.local` accepts `a.c-prot.local`
// and `a.b.c-prot.local`, but not the apex `c-prot.local` (add it explicitly)
// and not `evil-c-prot.local` — the leading dot is part of the compared suffix,
// so a suffix cannot be smuggled in as the tail of a longer label.
//
// Better Auth already understands the same pattern in `trustedOrigins`, so
// `deriveAuthTrustedOrigins` needs no matching change: it emits
// `http(s)://*.c-prot.local[:port]`, which Better Auth matches as a wildcard.
// See .github/FORK-POLICY.md.
function matchesWildcardHostname(hostname: string, allowSet: Set<string>): boolean {
  for (const entry of allowSet) {
    if (!entry.startsWith("*.")) continue;
    const suffix = entry.slice(1);
    if (suffix.length <= 1) continue;
    if (hostname.length > suffix.length && hostname.endsWith(suffix)) return true;
  }
  return false;
}

export function resolvePrivateHostnameAllowSet(opts: { allowedHostnames: string[]; bindHost: string }): Set<string> {
  const configuredAllow = normalizeAllowedHostnames(opts.allowedHostnames);
  const bindHost = opts.bindHost.trim().toLowerCase();
  const allowSet = new Set<string>(configuredAllow);

  if (bindHost && bindHost !== "0.0.0.0") {
    allowSet.add(bindHost);
  }
  allowSet.add("localhost");
  allowSet.add("127.0.0.1");
  allowSet.add("::1");
  return allowSet;
}

// The hostname comes from the request Host header, so an unauthenticated
// requester controls it. Never put that value into the guidance command. An
// operator or an agent can paste the guidance into a shell, and that outer
// shell evaluates a backtick, `$( )`, or `$NAME` span in the host before any
// CLI receives argv. A direct-exec form such as `npx` does not stop the
// outer shell. Emit a static `<host>` placeholder and do not echo the raw request
// value. The operator supplies the real hostname.
const BLOCKED_HOSTNAME_MESSAGE =
  "This hostname is not allowed for this Paperclip instance. " +
  "If you want to allow a hostname, run npx paperclipai allowed-hostname <host>.";

export function privateHostnameGuard(opts: {
  enabled: boolean;
  allowedHostnames: string[];
  bindHost: string;
}): RequestHandler {
  if (!opts.enabled) {
    return (_req, _res, next) => next();
  }

  const allowSet = resolvePrivateHostnameAllowSet({
    allowedHostnames: opts.allowedHostnames,
    bindHost: opts.bindHost,
  });

  return (req, res, next) => {
    const hostname = extractHostname(req);
    const wantsJson = req.path.startsWith("/api") || req.accepts(["json", "html", "text"]) === "json";

    if (!hostname) {
      const error = "Missing Host header. If you want to allow a hostname, run npx paperclipai allowed-hostname <host>.";
      if (wantsJson) {
        res.status(403).json({ error });
      } else {
        res.status(403).type("text/plain").send(error);
      }
      return;
    }

    if (
      isLoopbackHostname(hostname)
      || allowSet.has(hostname)
      || matchesWildcardHostname(hostname, allowSet)
    ) {
      next();
      return;
    }

    const error = BLOCKED_HOSTNAME_MESSAGE;
    if (wantsJson) {
      res.status(403).json({ error });
    } else {
      res.status(403).type("text/plain").send(error);
    }
  };
}
