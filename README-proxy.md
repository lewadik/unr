# Control UI on a real domain with TLS

Puts the OpenClaw Control UI behind Nginx Proxy Manager at
`https://<OPENCLAW_DOMAIN>/` with a Let's Encrypt certificate.

## How it fits together

```
browser ──HTTPS:443──> nginx-proxy-manager ──HTTP──> openclaw-gateway:18789
                       (TLS termination,             (bind: lan, token auth,
                        websocket upgrade)              trusts NPM's IP)
```

The Gateway port is **not** published to the host. Only NPM's 80/443 are.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | Stack + one-shot `npm-init` service (profile `init`) |
| `npm-init.sh` | Creates/updates the NPM proxy host via its API. Idempotent. |
| `apply-openclaw-proxy-config.sh` | Sets the four Gateway config keys this needs |
| `.env.example` | All variables — copy to `.env` |

## Setup

### 1. Configure

```bash
cp .env.example .env && chmod 600 .env
```

Fill in:

```dotenv
OPENCLAW_DOMAIN=openclaw.example.com   # must resolve to this host
OPENCLAW_GATEWAY_TOKEN=...             # openssl rand -hex 32
OPENCLAW_TLS_ENABLED=true
NPM_ADMIN_EMAIL=admin@example.com
NPM_ADMIN_PASSWORD=***                # NPM's default until you change it
```

### 2. Start NPM and the Gateway

```bash
docker compose up -d nginx-proxy-manager openclaw-gateway
```

Complete OpenClaw onboarding first if this is a fresh state volume — the Gateway
needs an `openclaw.json` before config keys can be set.

### 3. Create the proxy host

```bash
docker compose --profile init run --rm npm-init
```

Safe to re-run: it detects an existing host for the same domain and skips it.
Pass `NPM_UPDATE_EXISTING=true` to overwrite instead.

### 4. Configure the Gateway

```bash
docker compose cp apply-openclaw-proxy-config.sh openclaw-gateway:/tmp/
docker compose exec -e OPENCLAW_DOMAIN="$OPENCLAW_DOMAIN" -e NPM_IP="${NPM_IP:-172.28.0.10}" \
  openclaw-gateway bash /tmp/apply-openclaw-proxy-config.sh
docker compose restart openclaw-gateway
```

### 5. Sign in

```bash
docker compose exec openclaw-gateway openclaw gateway auth-token --show
```

Open `https://<OPENCLAW_DOMAIN>/` and paste the token in Settings.

---

## The four settings that matter

These are the only Gateway keys that make or break this setup. Each is set by
`apply-openclaw-proxy-config.sh`.

### `gateway.bind = lan` — without it, nothing connects

The image default is `loopback`, which listens on `127.0.0.1` **inside the
container**. NPM reaches the Gateway over the bridge network on `eth0`, so with
`loopback` every proxied request fails to connect. Use the bind *mode* name
(`lan`), not an address like `0.0.0.0`.

Requires a Gateway restart.

### `gateway.trustedProxies = ["172.28.0.10"]` — without it, everything 403s

When the Gateway sees proxy headers from an address not in `trustedProxies`, it
refuses to attribute the connection and rejects the request with
`proxy_attribution_required` **before auth is evaluated**.

This is why NPM is pinned to a fixed IP (`172.28.0.10`) instead of trusting the
whole bridge subnet. Trust exactly one hop.

Hot-applies.

### `gateway.publicOrigin = https://<domain>` — supplies the origin allowlist

The browser-origin check is fail-closed for public hostnames. When
`controlUi.allowedOrigins` is **omitted**, `publicOrigin` supplies the effective
allowlist — so set the one origin and nothing else.

Must be `scheme://host[:port]` with no path, query, or credentials. HTTP is only
accepted for literal loopback hosts.

Hot-applies.

### `gateway.auth.mode = token` — non-loopback binds require auth

A non-loopback bind with no auth path configured makes the Gateway refuse
WebSocket connections entirely (fail-closed). Token mode keeps the secret in
`OPENCLAW_GATEWAY_TOKEN`.

Requires a Gateway restart.

> `gateway.auth.token` is **mutually exclusive** with `trusted-proxy` mode. This
> setup uses token auth, so NPM only terminates TLS and forwards — it does not
> assert user identity. To have NPM authenticate users for you, that is a
> separate design using `auth.mode: trusted-proxy`, an identity header, and NPM
> Access Lists.

### Also set

- `gateway.allowRealIpFallback = false` — NPM sends `X-Forwarded-For`, so the
  `X-Real-IP` fallback is unnecessary and is a hardening risk.
- `controlUi.allowedOrigins` — deliberately **unset**. Setting `["*"]` trips a
  CRITICAL security audit finding; setting it at all would override the
  `publicOrigin` default.

---

## NPM proxy host details

Created by `npm-init.sh` through NPM's API:

| Field | Value | Why |
|---|---|---|
| `forward_scheme` / `host` / `port` | `http` / `openclaw-gateway` / `18789` | Container DNS on the shared `frontend` network |
| `allow_websocket_upgrade` | **`true`** | The Gateway multiplexes WebSocket + HTTP on 18789. Without this the UI loads and then never connects. |
| `letsencrypt_agree` | `true` | Request a Let's Encrypt cert (`certificate_id: 0`) |
| `ssl_forced` | `true` | Redirect HTTP → HTTPS |
| `hsts_enabled` | `true` | TLS hardening belongs at the proxy when the proxy terminates TLS |
| `block_exploits` | `true` | NPM's built-in rules |

**Let's Encrypt prerequisites:** the domain must resolve publicly to this host,
and port 80 must be reachable (HTTP-01 challenge). If issuance fails, NPM keeps
the host on HTTP — fix DNS and re-run with `NPM_UPDATE_EXISTING=true`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `proxy_attribution_required`, HTTP 403 | `gateway.trustedProxies` missing NPM's IP. Check `docker inspect npm --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'` matches `NPM_IP`. |
| Connection refused / 502 from NPM | `gateway.bind` still `loopback`. Set `lan` and restart. |
| UI loads but never connects, no session | WebSocket upgrade off in NPM, or `forward_port` wrong. |
| `origin not allowed` | Browser origin doesn't match `gateway.publicOrigin` exactly — including scheme and port. Private LAN / `.local` / `.ts.net` loads are exempt; public hostnames are not. |
| Cert not issued, host stuck on HTTP | DNS not resolving here, or port 80 blocked. |
| WebSocket auth fails with trusted-proxy guidance | You enabled `auth.mode: trusted-proxy` without `allowLoopback`/proper headers. Use token mode, or complete the trusted-proxy design. |

Verify end to end:

```bash
# Gateway alive
docker compose exec openclaw-gateway sh -lc 'curl -fsS http://127.0.0.1:18789/healthz'

# Through NPM (from the host)
curl -fsSI https://<OPENCLAW_DOMAIN>/healthz

# Config actually applied
docker compose exec openclaw-gateway openclaw config get gateway.trustedProxies
```

---

## Security notes

- **Do not publish `18789` to the host.** The Gateway is reachable only via NPM.
  If you uncommented the `ports:` block for setup, re-comment it afterwards.
- The Control UI runs with your full operator authority. Put an NPM **Access
  List** on the proxy host if the domain is internet-facing, or keep it behind
  Tailscale/VPN with `OPENCLAW_TLS_ENABLED=false`.
- `npm-init` needs NPM admin credentials. Rotate the NPM admin password away
  from `changeme` immediately, and keep `.env` at `chmod 600`.
- `gateway.trustedProxies` is a trust grant: anything at that IP can assert a
  client address. Keep it to the single pinned NPM IP.

## Source

OpenClaw docs consulted for the above:
`install/docker.md`, `install/docker/networking-and-storage.md`,
`install/docker/environment-variables.md`, `install/exe-dev.md`,
`gateway/config-gateway.md`, `gateway/security/network-exposure.md`,
`gateway/trusted-proxy-auth.md`.
