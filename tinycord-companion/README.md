# TinyCord Companion

An optional Ubuntu service for TinyCord on Apple Watch. The Watch uses HTTPS;
Companion maintains the Discord WebSocket, requests presence, and relays live
message and typing events. The Watch never needs a direct WebSocket.

## Deploy on Ubuntu 24.04+

For a host that already runs Caddy, see the
[existing-Caddy deployment guide](DEPLOYMENT.md). It uses the provided systemd
unit rather than a second Caddy container.

Use a domain such as `companion.example.com` whose DNS A (and, if configured,
AAAA) records point to the server. Allow inbound TCP **80 and 443** in your
hosting firewall. These ports must be available; the installer does not replace
an existing web server or change firewall rules. Outbound HTTPS/WSS to Discord
and certificate authorities must be allowed.

Copy this directory to the server, then run:

```bash
cd tinycord-companion
sudo bash install.sh companion.example.com you@example.com
curl --fail https://companion.example.com/healthz
```

The installer installs Ubuntu's Docker and Compose packages, builds the service,
validates Caddy, and starts both containers. It preserves an existing `.env`.
Caddy automatically obtains a publicly trusted certificate and renews it; keep
DNS correct, ports accessible, and the `caddy_data` volume. Certificate issuance
depends on the domain being reachable and ACME rate limits. No Discord token is
part of installation or environment configuration.

If Docker is already installed, manual deployment is:

```bash
cp .env.example .env
# Edit COMPANION_DOMAIN and ACME_EMAIL in .env.
docker compose config --quiet
docker compose up -d --build
```

Plain HTTP application requests return **426 HTTPS required**, rather than being
proxied or redirected. Port 80 is also used for ACME validation. HTTPS requires
TLS 1.2 or 1.3 and sends HSTS. The backend has no published port and is reachable
only within the Docker network. Its `X-Forwarded-Proto` check trusts **only this
deployment topology**, where Caddy overwrites the header. Do not expose backend
port 8080 or use untrusted containers on the same network.

To use an existing trusted gateway proxy, set `DISCORD_GATEWAY_URL` in `.env` to
its full `wss://.../?v=10&encoding=json` URL and recreate the service. The Watch
cannot supply arbitrary upstream URLs. Legacy gateway URLs in endpoint profiles
are migration metadata and are no longer used by the Watch.

## Enable on your Watch

On iPhone, add or edit a **custom endpoint profile**, enable **Use TinyCord
Companion**, and enter `https://companion.example.com`. Save and sync to Watch.
API/CDN URLs remain your normal Discord or proxy endpoints. To use official
Discord REST with Companion, create a custom profile with API
`https://discord.com/api/v10` and CDN `https://cdn.discordapp.com`.

On Watch, use **Settings → Endpoints → Configure Companion** for a custom
profile, or configure it while adding a custom host. Addresses must be HTTPS
origins with no credentials, path, query, or fragment; redirects are refused.
The Settings connection test verifies REST separately from Companion status.

While TinyCord is active, Companion requests:

- User session: mobile identity (`Discord iOS`), activity presence
  **Active on Apple Watch**.
- Bot session: online and a playing activity with the same text; bots do not
  receive the user mobile behavior. Gateway intents must be
  permitted for the bot.

The activity is sent with Gateway opcode 3 after READY and uses type 0, never
Custom Status (type 4). No account-settings REST request is made. User
availability reported in READY/user-settings events (Online, Idle, DND or
Invisible) is respected; if Discord doesn't report it, the session defaults to
Online. Discord may prefix the activity with “Playing” and controls its display.

Discord determines how these requests appear alongside your other sessions.
User-token gateway access/mobile identification is not a supported bot OAuth
feature, can change, and automated user accounts are against Discord's rules.
Payloads are tested with a mock gateway; verify the visible indicator using a
second account on a physical Watch before relying on it. This service doesn't
claim to override another Discord client's presence or global custom status.

The Watch renews a **10-second lease every three seconds** while active, and sends
DELETE on becoming inactive/backgrounded, logout, or a profile change. If that
request is lost, expiry closes the gateway within about 10 seconds of the last
renewal. Long-poll responses do **not** renew presence. This prevents a pending
request from keeping you online after leaving TinyCord. This is not a background
notification service.

## Stickers

PNG/APNG and GIF stickers use the configured CDN. Lottie stickers (Discord
format 3) have JSON assets, not PNG assets. When Companion is enabled, the Watch
requests `/v1/stickers/<id>.png`; Companion downloads the public JSON from
Discord's fixed CDN and renders it as a transparent animated PNG using rlottie
and Pillow. No Discord token or live presence session is needed for this route.
Without Companion, the Watch shows the sticker name and an enablement hint.

Rendering runs in a separate process with a ten-second wall timeout, CPU/memory
limits on Linux, 160-pixel output, at most 120 frames, and no external image
assets. One render runs at a time; concurrent requests for the same sticker are
combined. Downloads/output are capped at 2 MiB; a bounded 16 MiB in-memory cache
holds rendered public sticker images. Nothing is written to disk. Update all
three Python files and install requirements when upgrading a systemd deployment.

## Token and session handling

Companion must receive a Discord token transiently to send IDENTIFY. It does
**not** save tokens to disk, databases, environment variables, logs, or live
session objects. The reference is discarded immediately after IDENTIFY is sent.
It does not retain credentials for RESUME or automatic server-side reconnects;
a lost socket requires the active Watch to authenticate again.

Transient copies exist in process, HTTP, WebSocket, and TLS buffers during
authentication. Python cannot guarantee physical zeroization of every memory
copy. A promise that the server never receives a token, or never has one in RAM,
would be incompatible with authenticating Discord on the Watch's behalf.

The provided containers disable swap, core dumps, and Docker logs. The app has a
read-only filesystem and no data volumes. Caddy access logging is not enabled
and its runtime log output is discarded. Only Caddy certificate/account/config
data persists. Do not add request/body logging, debugging dumps, traffic-capture
agents, or host/VM memory snapshots if retaining token bytes is unacceptable.
The operator can inspect live memory; use a server you control and trust.

Live session state consists of a socket, Discord user ID, heartbeat/sequence
state, an expiring lease, and a bounded in-memory event queue (128 events / 2 MiB).
READY payloads are never relayed or queued. Random Watch-generated relay
credentials are separate from Discord tokens; only their SHA-256 digests are
used as server lookup keys. Restarts lose all sessions and buffered events.
Deleted relay credential digests are kept for up to two minutes (at most 4096)
to reject authentication requests that arrive after their cancellation.
There is a 100-session ceiling and a global 30-new-session-attempts/minute limit.
This is a small self-hosted service, not a public multi-tenant hosting platform.

## HTTPS protocol

Every session request uses `Authorization: Bearer <random relay credential>`.
The Watch generates a new credential for each connection, with at least 40
URL-safe characters. Never use the Discord token as that credential.

| Request | Behavior |
| --- | --- |
| `POST /v1/session` | JSON `{ "token": "…", "isBot": false }`; returns 201 only after Discord READY. Same relay credential is idempotent. |
| `PUT /v1/session` | Renews the lease for an active Watch; returns current state. |
| `GET /v1/events?after=0` | Waits up to 20 seconds. Returns `state`, `events`, `cursor`, and `reset`. One concurrent poll per session. |
| `DELETE /v1/session` | Closes the WebSocket and removes the session; idempotent 204. |
| `GET /v1/stickers/<id>.png` | Public Lottie-to-APNG rendering; only numeric Discord sticker IDs accepted. |
| `GET /healthz` | Public health response; doesn't contact Discord. |

Events are `{ "id": 1, "type": "MESSAGE_CREATE", "data": {…} }`. The client
uses the returned cursor for the next poll. Events remain replayable until
evicted; `reset: true` means refresh from REST. Only MESSAGE_CREATE,
MESSAGE_DELETE, and TYPING_START are relayed. Expired sessions return 404;
disconnected sessions require fresh authentication. All responses use no-store.

## Maintenance and testing

```bash
# Apply source/dependency updates, retaining certificates.
docker compose build --pull
docker compose pull caddy
docker compose up -d
docker compose ps

# Stop; active gateway sessions are closed.
docker compose down

# Local integration tests (Python 3.11+; synthetic credentials only).
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v

# Optional local test of the shipped HTTPS policy with a Caddy binary.
CADDY_BIN=/path/to/caddy .venv/bin/python tests/verify_tls.py
```

Use HTTPS `/healthz`, `docker compose ps`, and Watch status to diagnose failures.
There are intentionally no request logs to inspect. Failed authentication
returns a generic 502 without reflecting credentials or upstream payloads.
Watch retries use backoff and then fall back to REST; tap Retry after correcting
the endpoint or credential. Public certificate issuance and real Discord
presence require deployment and a live-account/device test.
