# Deploy behind an existing Caddy

This setup uses a systemd service and your existing Caddy instance. Replace
`companion.example.com` with your own domain and point its DNS to your server.
Do not run the Docker installer on a host where Caddy already owns ports 80/443.

## Install the service

Copy `server.py`, `stickers.py`, `sticker_renderer.py`, `requirements.txt`, and
`tinycord-companion.service` into
`/opt/tinycord-companion`, then run on Ubuntu:

```bash
sudo apt-get install -y python3-venv
sudo python3 -m venv /opt/tinycord-companion/.venv
sudo /opt/tinycord-companion/.venv/bin/pip install -r /opt/tinycord-companion/requirements.txt
sudo install -m 644 /opt/tinycord-companion/tinycord-companion.service /etc/systemd/system/tinycord-companion.service
sudo systemctl daemon-reload
sudo systemctl enable --now tinycord-companion
```

The service listens on `127.0.0.1:8787`. It runs as a dynamic unprivileged user
with a read-only filesystem, disabled application logs, no core dumps, and
`MemorySwapMax=0`. No Discord credentials belong in deployment files.

## Configure Caddy

Back up your existing Caddy configuration, then add these site blocks:

```caddyfile
https://companion.example.com {
    tls {
        protocols tls1.2 tls1.3
    }
    header {
        Strict-Transport-Security "max-age=31536000"
        Cache-Control "no-store"
        -Server
    }
    request_body {
        max_size 8KB
    }
    reverse_proxy 127.0.0.1:8787 {
        header_up X-Forwarded-Proto https
        transport http {
            response_header_timeout 30s
        }
    }
}

http://companion.example.com {
    respond "HTTPS required" 426
}
```

Caddy obtains and renews the certificate using its ACME configuration. Permit
inbound TCP 80/443 and keep the domain's DNS correct. Caddy's default protocol
negotiation supports HTTP/1.1, HTTP/2 and HTTP/3; no HTTP/1.1-only override is
needed. Do not enable request-body logging or publicly expose the backend port.

Validate the configuration before reloading:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
systemctl is-active caddy tinycord-companion
curl --fail https://companion.example.com/healthz
sudo systemctl show tinycord-companion -p MemorySwapMax -p LimitCORE
sudo ss -ltnp 'sport = :8787'
```

## Update and configure the app

Copy updated application files into `/opt/tinycord-companion`, install the
requirements using its virtual environment, and restart `tinycord-companion`.

In a custom endpoint profile, enable Companion and enter your HTTPS origin.
When Companion is enabled, iPhone Auto-fill derives `https://companion.<base-host>`
alongside the API and CDN URLs. Watch Companion configuration also has an
Auto-fill button. Review the generated address to match your deployment.

Keep actual deployment domains, hostnames, IPs and operator-specific notes
outside this repository. `.env` is ignored; use `.env.example` as a template.

## Optional main Gateway proxy for voice calls

Use a separate host with a fixed Discord upstream. Caddy handles the WebSocket
upgrade automatically; keep normal TLS verification and protocol negotiation.
This proxies call signaling only, not Discord's Voice Gateway or UDP audio.

```caddyfile
https://gateway.example.com {
    tls {
        protocols tls1.2 tls1.3
    }
    header {
        Strict-Transport-Security "max-age=31536000"
        Cache-Control "no-store"
        -Server
    }
    reverse_proxy https://gateway.discord.gg {
        header_up Host gateway.discord.gg
        transport http {
            tls_server_name gateway.discord.gg
        }
    }
}

http://gateway.example.com {
    respond "WSS required" 426
}
```

Back up the existing Caddyfile, add the blocks, validate, and reload Caddy.
Verify a WSS connection to `/?v=10&encoding=json` receives opcode 10 (HELLO)
without sending an account token. Recheck Companion `/healthz` afterwards.
The Watch uses this endpoint only inside an active CallKit call; normal online
status and messaging continue through Companion's HTTPS API.
