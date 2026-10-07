#!/usr/bin/env bash
# Prepares a fresh Ubuntu server to run n8n behind a Cloudflare Tunnel.
#
# Run it from inside this folder with:  bash setup.sh
#
# It is safe to run more than once, because each step checks what already exists
# before changing anything. Your existing .env, for example, is never overwritten,
# since replacing the encryption key would lock n8n out of your saved logins.

set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nSTOPPED: %s\n' "$1" >&2; exit 1; }

# Step 1: Docker, which runs both n8n and the Cloudflare connector.
if command -v docker >/dev/null 2>&1; then
  say "Docker is already installed, so this step is skipped."
else
  say "Installing Docker. This usually takes one or two minutes."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi
# Docker must also start by itself after a reboot, otherwise n8n would stay down
# until someone logged in and started it by hand.
if ! sudo systemctl enable --now docker >/dev/null 2>&1; then
  echo "Note: could not set Docker to start after a reboot. Setup will continue, but mention this to Claude."
fi

# Step 2: the private settings file.
if [ -f .env ]; then
  say "Found an existing .env file, so your current settings are kept."
else
  say "Creating your private settings file (.env). Three questions follow."

  read -rp "1. Your n8n address without https:// (for example n8n.example.com): " host
  host="${host#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  [ -n "$host" ] || fail "The address cannot be empty. Run bash setup.sh again."

  echo "2. Your timezone, so schedules run at your local time."
  echo "   Examples: Africa/Lagos, Europe/London, America/New_York"
  read -rp "   Timezone [Etc/UTC]: " tz
  tz="${tz:-Etc/UTC}"
  [ -f "/usr/share/zoneinfo/$tz" ] || fail "\"$tz\" is not a timezone name this server knows. Run bash setup.sh again."

  echo "3. Paste the Cloudflare Tunnel token (the long text starting with eyJ)."
  echo "   Nothing will appear while you paste, which is deliberate. Press Enter afterwards."
  read -rsp "   Token: " token
  echo
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  [ -n "$token" ] || fail "The token cannot be empty. Run bash setup.sh again."
  case "$token" in
    eyJ*) ;;
    *) fail "That does not look like a tunnel token, since it should start with eyJ. Copy only the token, not the whole command, and run bash setup.sh again." ;;
  esac

  key="$(openssl rand -hex 32)"

  # umask 077 makes the new file readable by your user only.
  (
    umask 077
    {
      echo "N8N_HOSTNAME=$host"
      echo "GENERIC_TIMEZONE=$tz"
      echo "CLOUDFLARE_TUNNEL_TOKEN=$token"
      echo "N8N_ENCRYPTION_KEY=$key"
    } > .env
  )
  say "Saved .env. Back this file up somewhere safe later, as the README explains."
fi

# Step 3: a shared folder n8n may read and write. The n8n container runs as user
# 1000, so the folder has to belong to that user or n8n cannot save files into it.
mkdir -p local-files
sudo chown 1000:1000 local-files

# Step 4: download and start both services.
say "Downloading n8n and the Cloudflare connector. The first run takes a few minutes."
sudo docker compose pull
sudo docker compose up -d

# Step 5: wait until n8n is ready. The readiness address is used rather than the
# plain health one, because the plain one answers "ok" while n8n is still
# preparing its database, which would declare success too early.
say "Waiting for n8n to start. The first start prepares its database, so allow a minute or two."
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:5678/healthz/readiness >/dev/null 2>&1; then
    n8n_ok=1
    break
  fi
  sleep 3
done
if [ "${n8n_ok:-0}" != 1 ]; then
  fail "n8n did not start within three minutes. Show Claude the output of: sudo docker compose logs n8n --tail 50"
fi
say "n8n is running on this server."

# Step 6: confirm the tunnel reached Cloudflare.
sleep 5
if sudo docker compose logs cloudflared 2>&1 | grep -q "Registered tunnel connection"; then
  say "The Cloudflare Tunnel is connected."
else
  echo
  echo "The tunnel has not reported a connection yet. Wait a minute, then check with:"
  echo "  sudo docker compose logs cloudflared --tail 30"
  echo "If it says the token is not valid, delete .env with  rm .env  and run bash setup.sh again."
fi

host_now="$(grep '^N8N_HOSTNAME=' .env | cut -d= -f2-)"
cat <<EOF

All done on the server side.
Next, open https://$host_now in your browser and continue from step 7 of the README.
EOF
