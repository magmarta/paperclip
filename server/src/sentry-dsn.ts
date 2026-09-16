// Resolves the Sentry DSN for each component from the process environment.
//
// Precedence: a specific variable always wins for its own component.
// `SENTRY_DSN` supplies a component that has no specific value set.
// An empty string counts as absent for every variable, so a specific
// variable set to `""` still falls back to `SENTRY_DSN`.
//
// To add a DSN for a new component, add a field to `SentryDsns`, add a
// variable named with the shared `SENTRY_DSN_` prefix, and resolve it with
// `normalize` the same way `frontend` and `backend` resolve here.

export interface SentryDsns {
  frontend: string | null;
  backend: string | null;
  legacyFallbackUsed: boolean;
}

function normalize(value: string | undefined): string | null {
  return value ? value : null;
}

export function resolveSentryDsns(env: NodeJS.ProcessEnv = process.env): SentryDsns {
  // magmarta fork policy (d): Sentry error reporting is permanently off, so
  // no stack traces or breadcrumbs leave the instance even if SENTRY_DSN is
  // set in the environment. See .github/FORK-POLICY.md.
  void env;
  return { frontend: null, backend: null, legacyFallbackUsed: false };
  const legacy = normalize(env.SENTRY_DSN);
  const specificFrontend = normalize(env.SENTRY_DSN_FRONTEND);
  const specificBackend = normalize(env.SENTRY_DSN_BACKEND);

  const frontend = specificFrontend ?? legacy;
  const backend = specificBackend ?? legacy;
  const legacyFallbackUsed = (specificFrontend === null || specificBackend === null) && legacy !== null;

  return { frontend, backend, legacyFallbackUsed };
}
