#!/usr/bin/env bash
# Ubuntu 24.04+; run from a checkout, after DNS points to this server.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ ${EUID} -ne 0 ]]; then
    echo "Run with sudo: sudo bash install.sh companion.example.com you@example.com" >&2
    exit 1
fi
if [[ $# -ne 2 ]] || [[ ! $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || [[ ! $2 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Usage: sudo bash install.sh companion.example.com you@example.com" >&2
    exit 1
fi
if [[ ! -f .env ]]; then
    umask 077
    printf 'COMPANION_DOMAIN=%s\nACME_EMAIL=%s\n' "$1" "$2" > .env
else
    echo "Keeping existing .env configuration."
fi
apt-get update
apt-get install -y docker.io docker-compose-v2
systemctl enable --now docker
docker compose config --quiet
docker compose build --pull
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d
echo "TinyCord Companion started. DNS and inbound TCP 80/443 must reach this server for automatic certificates."
echo "Verify: curl --fail https://YOUR_CONFIGURED_DOMAIN/healthz"
