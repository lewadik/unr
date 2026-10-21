#!/bin/sh
# Creates the Nginx Proxy Manager proxy host that terminates TLS for the
# OpenClaw Control UI. Idempotent.
#
# Requires: curl, jq (installed below), and a reachable NPM API.
set -eu

NPM_API="${NPM_API_URL:-http://npm:81}"
EMAIL="${NPM_ADMIN_EMAIL:?NPM_ADMIN_EMAIL is required}"
PASS="${NPM_ADMIN_PASSWORD:?NPM_ADMIN_PASSWORD is required}"
DOMAIN="${OPENCLAW_DOMAIN:?OPENCLAW_DOMAIN is required}"
UP_HOST="${OPENCLAW_UPSTREAM_HOST:-openclaw-gateway}"
UP_PORT="${OPENCLAW_UPSTREAM_PORT:-18789}"
UPDATE_EXISTING="${NPM_UPDATE_EXISTING:-false}"

case "${OPENCLAW_TLS_ENABLED:-true}" in
  true|1|yes|on) TLS=1 ;;
  *)             TLS=0 ;;
esac

log() { printf '[npm-init] %s\n' "$*"; }
die() { printf '[npm-init] ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null
command -v jq   >/dev/null 2>&1 || apk add --no-cache jq   >/dev/null

# ── Wait for the NPM API ──────────────────────────────────────────────
# An unauthenticated GET /api/tokens answers 401 once the API is serving.
log "waiting for NPM API at ${NPM_API} ..."
attempt=0
while :; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${NPM_API}/api/tokens" || echo 000)"
  [ "$code" = "401" ] || [ "$code" = "200" ] && break
  attempt=$((attempt + 1))
  [ "$attempt" -ge 60 ] && die "NPM API never became ready (last HTTP ${code})"
  sleep 5
done
log "NPM API ready"

# ── Authenticate ─────────────────────────────────────────────────────
log "logging in as ${EMAIL}"
TOKEN="$(curl -fsS -X POST "${NPM_API}/api/tokens" \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":\"${EMAIL}\",\"secret\":\"${PASS}\"}" \
  | jq -r '.token // empty')"
[ -n "$TOKEN" ] || die "login failed — check NPM_ADMIN_EMAIL / NPM_ADMIN_PASSWORD"
AUTH="Authorization: Bearer ${TOKEN}"

# ── Check for an existing host ───────────────────────────────────────
EXISTING="$(curl -fsS "${NPM_API}/api/nginx/proxy-hosts" -H "$AUTH" \
  | jq -r --arg d "$DOMAIN" \
      '[.[] | select(.domain_names | index($d) != null) | .id] | first // empty')"

if [ -n "$EXISTING" ] && [ "$UPDATE_EXISTING" != "true" ]; then
  log "proxy host for ${DOMAIN} already exists (id ${EXISTING}) — nothing to do"
  log "set NPM_UPDATE_EXISTING=true to overwrite it"
  exit 0
fi

# ── Build the payload ────────────────────────────────────────────────
# allow_websocket_upgrade: REQUIRED — the Control UI multiplexes WebSocket
#   and HTTP on port 18789. Without it the UI loads but never connects.
# hsts_enabled / ssl_forced: TLS hardening at the proxy, per OpenClaw docs.
# certificate_id 0 + letsencrypt_agree: NPM obtains a Let's Encrypt cert.
#   Needs the domain publicly resolving to this host and port 80 reachable.
PAYLOAD="$(jq -n \
  --arg     domain "$DOMAIN" \
  --arg     host   "$UP_HOST" \
  --argjson port   "$UP_PORT" \
  --argjson tls    "$TLS" \
  '{
    domain_names:            [$domain],
    forward_scheme:          "http",
    forward_host:            $host,
    forward_port:            $port,
    access_list_id:          "0",
    certificate_id:          0,
    meta: {
      letsencrypt_agree: ($tls == 1),
      dns_provider:      ""
    },
    advanced_config:         "",
    enabled:                 true,
    ssl_forced:              ($tls == 1),
    hsts_enabled:            ($tls == 1),
    hsts_subdomains:         false,
    block_exploits:          true,
    allow_websocket_upgrade: true
  }')"

# ── Create or update ─────────────────────────────────────────────────
if [ -n "$EXISTING" ]; then
  log "updating existing proxy host id ${EXISTING} for ${DOMAIN}"
  curl -fsS -X PUT "${NPM_API}/api/nginx/proxy-hosts/${EXISTING}" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "$PAYLOAD" >/dev/null || die "PUT failed"
else
  log "creating proxy host ${DOMAIN} -> http://${UP_HOST}:${UP_PORT}"
  curl -fsS -X POST "${NPM_API}/api/nginx/proxy-hosts" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "$PAYLOAD" >/dev/null || die "POST failed"
fi

log "done. Control UI will be at https://${DOMAIN}/"
if [ "$TLS" = "1" ]; then
  log "Let's Encrypt issuance needs DNS for ${DOMAIN} -> this host and port 80 open."
  log "If issuance fails, NPM keeps the host on HTTP; retry after DNS resolves."
fi
