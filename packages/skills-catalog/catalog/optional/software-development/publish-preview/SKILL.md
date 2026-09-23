---
name: publish-preview
description: >
  Publish a running app from this host at a real HTTPS subdomain so a person can
  open it. Covers the `paperclip-preview` helper (DNS, Cloudflare Access, nginx,
  TLS), when a static site should go to Cloudflare Workers instead, and the
  `preview_url` work product that carries the link back to the board.
key: paperclipai/optional/software-development/publish-preview
recommendedForRoles:
  - engineer
tags:
  - preview
  - deployment
  - cloudflare
  - nginx
  - docker
requires:
  - sudo
  - paperclip-preview
---

# Publish a Preview

A person cannot open `localhost`. When work needs to be looked at, tried, or
demoed, it needs a real address. This skill covers publishing one from this
host.

## When to use

- A reviewer, the board, or the user needs to click something and see it run.
- The app has a backend, a dev server, a database, or WebSockets.
- The app runs in Docker on this host and listens on a local port.

## When not to use

- **The deliverable is a purely static site** (HTML/CSS/JS, no server code).
  Deploy it to Cloudflare Workers instead — no host, no nginx, no port, no
  certificate, and it stays up when this machine does not. Use a `wrangler.jsonc`
  with an `assets` directory and a `custom_domain` route; `wrangler deploy`
  creates the DNS record itself.
- The work is not runnable yet. Publish something a person can actually use.

## The contract

`paperclip-preview` owns three things at once — the Cloudflare DNS record, a
Cloudflare Access policy, and the nginx virtual host. Do not create any of them
by hand: a hand-made nginx file will be overwritten, and a hand-made DNS record
will not be cleaned up when the preview is removed.

The command needs `sudo`. That is already granted for this one command only.

### 1. Ask for the port

```sh
PORT=$(sudo paperclip-preview port my-app)
```

The name-to-port mapping is permanent, so the same project keeps the same port
across restarts and rebuilds. Names are lowercase letters, digits and hyphens.

### 2. Bind the app to that port

Whatever runs the app — `docker compose`, `docker run -p`, a dev server — must
listen on that port on this host.

### 3. Publish

```sh
sudo paperclip-preview add my-app
```

If the app is already running on a port that was chosen elsewhere, pass it and
the mapping is updated to match:

```sh
sudo paperclip-preview add my-app 8080
```

The command prints the address. It also warns when nothing is listening yet —
that warning means the address is live but the app is not, so check the app
before reporting the preview as ready.

### 4. Record it as a work product

A comment with a URL in it is not an access path. Create a `preview_url` work
product on the issue with the address as its `url`, so the board can find it
without reading the thread.

### 5. Remove it when the work is done

```sh
sudo paperclip-preview rm my-app
```

This deletes the DNS record, the Access application and the vhost. The port stays
reserved for the name; `forget` releases it too. Leaving dead previews behind
means DNS records pointing at nothing.

## Useful checks

```sh
sudo paperclip-preview list            # every preview, port, listening or not
sudo paperclip-preview status my-app   # one preview in detail
```

## What the address is protected by

Every preview sits behind Cloudflare Access. A visitor verifies an allow-listed
email address before the request reaches this host at all. This is deliberate:
a development server usually has no authentication of its own, and debug
endpoints and database UIs come with it.

So when a person reports that the link asks them to log in, that is the system
working. If they cannot get through, their address is not on the list — an
operator adds it with `ACCESS_EMAILS` in `/etc/paperclip-preview.conf`. Do not
work around Access by disabling it.

## Failure modes worth knowing

| Symptom | Cause |
|---|---|
| Page says "Uygulama henuz calismiyor" | Nothing is listening on the mapped port. Start the app. |
| `'<name>' rezerve bir isim` | The name collides with infrastructure. Pick another. |
| `Port N altyapiya ait` | That port belongs to the panel or the database. Use the assigned one. |
| Link redirects to a Cloudflare login | Expected. That is Access. |
