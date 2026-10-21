The stack includes the full proxy setup in `/home/leo/.openclaw/workspace/unraid-stack/`:

- **`docker-compose.yaml`** — added a one-shot `npm-init` service (profile `init`) and pinned NPM to a fixed IP (`172.28.0.10`) on an explicit subnet, so OpenClaw trusts exactly that hop
- **`npm-init.sh`** — creates the proxy host via NPM's API. Idempotent, websocket upgrade on, LE cert + HSTS + SSL-forced
- **`apply-openclaw-proxy-config.sh`** — sets the four Gateway keys that make-or-break this
- **`README-proxy.md`** — full runbook + troubleshooting
- **`.env.example`** — new vars: `OPENCLAW_DOMAIN`, `OPENCLAW_TLS_ENABLED`, `NPM_ADMIN_EMAIL`, `NPM_ADMIN_PASSWORD`, network pins

**The four settings that matter** (each researched against OpenClaw docs, not guessed):

1. `gateway.bind = lan` — default `loopback` listens inside the container only; NPM would get connection refused
2. `gateway.trustedProxies = ["172.28.0.10"]` — without it every request 403s with `proxy_attribution_required`
3. `gateway.publicOrigin = https://<domain>` — supplies the fail-closed browser-origin allowlist
4. `gateway.auth.mode = token` — non-loopback binds require auth

**To deploy:**
```bash
cd unraid-stack
cp .env.example .env && chmod 600 .env  # fill in OPENCLAW_DOMAIN + tokens
docker compose up -d nginx-proxy-manager openclaw-gateway
docker compose --profile init run --rm npm-init
docker compose cp apply-openclaw-proxy-config.sh openclaw-gateway:/tmp/
docker compose exec -e OPENCLAW_DOMAIN="$OPENCLAW_DOMAIN" -e NPM_IP="${NPM_IP:-172.28.0.10}" \
  openclaw-gateway bash /tmp/apply-openclaw-proxy-config.sh
docker compose restart openclaw-gateway
```
Then sign in at `https://<domain>/` with `docker compose exec openclaw-gateway openclaw gateway auth-token --show`.

**Gotchas baked into the design:** the Gateway port stays unpublished (only NPM's 80/443 are exposed), Let's Encrypt needs the domain resolving to the host + port 80 open, and I hit one real bug during validation — an apostrophe in `proxy's` inside `${VAR:?...}` broke bash's parser — fixed and re-verified.

Want the "NPM Access List" layer too (basic auth in front of the Control UI), or is this enough?
