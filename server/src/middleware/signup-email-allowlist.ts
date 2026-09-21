import type { Request, RequestHandler } from "express";

export type SignUpEmailAllowlistEntry = string;

// magmarta fork policy (i): only invited addresses may open an account.
//
// Upstream offers one lever here, `disableSignUp`, and it is all-or-nothing.
// That lever does not express "invited people only" on this deployment: the
// invite flow in `routes/access.ts` rejects an anonymous acceptance with
// "Human invite acceptance requires authenticated user", so an invitee has to
// register BEFORE the invite can be redeemed. Turning sign-up off therefore
// locks out the very people the invite was issued to, and leaving it on lets
// anyone who can reach the panel register.
//
// PAPERCLIP_AUTH_ALLOWED_SIGNUP_EMAILS closes that gap. An empty or unset list
// keeps upstream behaviour exactly (no restriction), so a host that never sets
// it is unaffected. Each entry is either a full address (`hasan@marta.tr`) or a
// domain wildcard (`*@marta.tr`).
//
// The wildcard match is deliberately narrow, mirroring patch (f): the `@` is
// part of the compared suffix, so `*@marta.tr` accepts `a@marta.tr` but not
// `a@evil-marta.tr` and not `a@sub.marta.tr` — list a subdomain explicitly if
// you need it. Sub-addressing (`a+tag@marta.tr`) is NOT stripped: the address
// is compared as sent, so a wildcard on the domain covers it either way while
// an exact entry stays exact.
//
// This guards the credential endpoint only. It is not a replacement for the
// authorization model — it stops account creation, not access granted later.
// See .github/FORK-POLICY.md.
export function normalizeSignUpEmailAllowlist(values: string[]): string[] {
  const unique = new Set<string>();
  for (const value of values) {
    const trimmed = value.trim().toLowerCase();
    if (!trimmed) continue;
    unique.add(trimmed);
  }
  return Array.from(unique);
}

export function isSignUpEmailAllowed(email: string, allowlist: string[]): boolean {
  // An empty list is "no allowlist configured", not "deny everything". A typo
  // that empties the variable must not lock the instance out of onboarding.
  if (allowlist.length === 0) return true;

  const normalized = email.trim().toLowerCase();
  if (!normalized) return false;

  const atIndex = normalized.lastIndexOf("@");
  if (atIndex <= 0 || atIndex === normalized.length - 1) return false;
  const domain = normalized.slice(atIndex + 1);

  for (const entry of allowlist) {
    if (entry.startsWith("*@")) {
      if (domain === entry.slice(2)) return true;
      continue;
    }
    if (normalized === entry) return true;
  }
  return false;
}

function extractSignUpEmail(req: Request): string | null {
  const body = req.body as { email?: unknown } | undefined;
  const email = body?.email;
  return typeof email === "string" ? email : null;
}

/**
 * Rejects `POST /api/auth/sign-up/email` for an address outside the allowlist.
 *
 * Mounted ahead of the Better Auth handler so the request never reaches the
 * credential store. Every other auth path — sign-in, sign-out, session — passes
 * straight through: this is a registration gate, not an access gate.
 */
export function signUpEmailAllowlistMiddleware(allowlist: string[]): RequestHandler {
  const normalized = normalizeSignUpEmailAllowlist(allowlist);

  return (req, res, next) => {
    if (normalized.length === 0) return next();
    if (req.method !== "POST") return next();

    // Mounted on /api/auth, so req.path is the remainder ("/sign-up/email").
    const path = req.path.replace(/\/+$/, "");
    if (path !== "/sign-up/email") return next();

    const email = extractSignUpEmail(req);
    if (email !== null && isSignUpEmailAllowed(email, normalized)) return next();

    // Better Auth's own shape, so the UI renders it like any other auth error.
    res.status(403).json({
      code: "SIGNUP_EMAIL_NOT_ALLOWED",
      message:
        "This email address is not allowed to create an account on this instance. Ask an administrator for an invitation.",
    });
  };
}
