#!/usr/bin/env bash
# Configures a containerized OpenClaw Gateway to sit behind Nginx Proxy Manager
# with TLS termination on a real domain.
#
# Run this INSIDE the openclaw-gateway container (it shares the state volume),
# after the Gateway has completed onboarding at least once.
#
#   docker compose exec openclaw-gateway bash -lc \
#     'OPENCLAW_DOMAIN=... NPM_IP=... bash -s' < apply-openclaw-proxy-config.sh
#
# Or copy the file in and run it there. See README-proxy.md.
set -euo pipefail

: "${OPENCLAW_DOMAIN:?OPENCLAW_DOMAIN is required (e.g. openclaw.example.com)}"
: "${NPM_IP:?NPM_IP is required - set it to the proxy container IP (default 172.28.0.10)}"

PUBLIC_ORIGIN="${PUBLIC_ORIGIN:-https://${OPENCLAW_DOMAIN}}"

log() { printf '\n==> %s\n' "$*"; }

log "Setting gateway.bind = lan"
# MANDATORY. The image default is 'loopback', which listens on 127.0.0.1 INSIDE
# the container only. NPM connects over the bridge network to eth0, so with
# 'loopback' every proxied request fails to connect. Use the bind MODE name,
# not an address like 0.0.0.0.
openclaw config set gateway.bind lan

log "Setting gateway.publicOrigin = ${PUBLIC_ORIGIN}"
# The externally reachable HTTPS origin. This single value supplies the default
# browser-origin allowlist when controlUi.allowedOrigins is omitted, so we do
# NOT need to set allowedOrigins separately. Must be scheme://host[:port] with
# no path, query, or credentials.
openclaw config set gateway.publicOrigin "${PUBLIC_ORIGIN}" --strict-json

log "Setting gateway.trustedProxies = [${NPM_IP}]"
# WITHOUT THIS EVERY REQUEST 403s with proxy_attribution_required.
# When the Gateway sees proxy headers (X-Forwarded-For) from an address that is
# not in trustedProxies, it refuses to treat the connection as attributable and
# rejects it before auth is even evaluated. Trust exactly the NPM container IP —
# do not widen this to the bridge subnet if you can avoid it.
openclaw config set gateway.trustedProxies "[\"${NPM_IP}\"]" --strict-json

log "Setting gateway.auth.mode = token"
# Non-loopback binds REQUIRE gateway auth (fail-closed). Token mode keeps the
# shared secret in OPENCLAW_GATEWAY_TOKEN. Do not use auth.mode "none" here.
#
# NOTE: gateway.auth.token and trusted-proxy mode are mutually exclusive. We use
# token mode, so NPM only terminates TLS and forwards — it does not assert user
# identity. If you want NPM to authenticate users for you, that is a separate
# setup using auth.mode "trusted-proxy" plus an identity header and Access Lists.
openclaw config set gateway.auth.mode token

log "Leaving controlUi.allowedOrigins unset"
# Deliberate. Per the docs, when allowedOrigins is omitted the effective
# allowlist is gateway.publicOrigin — exactly what we want for a single public
# domain. Setting ["*"] would trip a CRITICAL security audit finding.
openclaw config unset gateway.controlUi.allowedOrigins || true

log "Leaving allowRealIpFallback disabled"
# Only enable if your proxy genuinely cannot send X-Forwarded-For. NPM does.
openclaw config set gateway.allowRealIpFallback false

log "Resulting gateway config"
openclaw config get gateway.bind || true
openclaw config get gateway.publicOrigin || true
openclaw config get gateway.trustedProxies || true
openclaw config get gateway.auth.mode || true

log "Done"
cat <<'EOF'

Next steps:
  1. Restart the Gateway so the bind + auth changes take effect:
       docker compose restart openclaw-gateway
     (trustedProxies / publicOrigin hot-apply, but bind and auth.mode do not.)

  2. Confirm it is listening on the container's non-loopback interface:
       docker compose exec openclaw-gateway sh -lc \
         'curl -fsS http://127.0.0.1:18789/healthz'

  3. Retrieve the Control UI token to sign in:
       docker compose exec openclaw-gateway openclaw gateway auth-token --show

  4. Open https://<OPENCLAW_DOMAIN>/ and paste the token in Settings.

  5. If the browser shows "origin not allowed", the origin you typed into the
     address bar does not match gateway.publicOrigin exactly — including scheme
     and any port. Private LAN / .ts.net / .local loads are exempt; public
     hostnames are fail-closed.

EOF
