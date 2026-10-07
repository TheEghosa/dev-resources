#!/usr/bin/env bash
# Checks, from the Claude cloud session, that the n8n API can be reached through
# Cloudflare Access. It reads four secrets from the environment and never prints
# them, so its output is safe to share in the chat.
#
# Usage:  bash n8n-selfhost/check-connection.sh

set -uo pipefail

missing=0
for name in N8N_BASE_URL N8N_API_KEY CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET; do
  if [ -z "${!name:-}" ]; then
    echo "Missing secret: $name"
    missing=1
  fi
done
if [ "$missing" = 1 ]; then
  echo "Add the missing secrets in the environment settings, then start a new session, since secrets only load when a session starts."
  exit 1
fi

base="${N8N_BASE_URL%/}"
body="$(mktemp)"
errors="$(mktemp)"
trap 'rm -f "$body" "$errors"' EXIT

# Any redirect is reported rather than followed, because Access answers a request
# that lacks a valid service token by redirecting it to a login page.
code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Accept: application/json" \
  "$base/api/v1/workflows?limit=1" 2>"$errors")"

case "$code" in
  200)
    echo "Connected: Cloudflare Access accepted the service token and n8n accepted the API key."
    exit 0
    ;;
  401)
    echo "Cloudflare let the request through, but n8n rejected the API key (HTTP 401)."
    echo "Create a fresh key in n8n under Settings, n8n API, and update N8N_API_KEY."
    ;;
  302|303)
    echo "Cloudflare Access sent the request to a login page (HTTP $code)."
    echo "The n8n Access application probably lacks the Service Auth policy for the service token."
    ;;
  403)
    echo "The request was refused (HTTP 403). This has two common causes:"
    echo "  1. This session's network policy blocks the host, so add it under Allowed domains."
    echo "  2. Cloudflare Access rejected the service token, so check the Client ID, the secret and the Service Auth policy."
    ;;
  000)
    echo "No answer from $base. Check the address, and that the tunnel shows as Healthy in Cloudflare."
    echo "What curl reported: $(head -c 300 "$errors")"
    exit 1
    ;;
  *)
    echo "Unexpected answer: HTTP $code."
    ;;
esac

echo
echo "The first 300 characters of the reply, to help diagnose it:"
head -c 300 "$body"
echo
exit 1
