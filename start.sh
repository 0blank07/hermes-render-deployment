#!/bin/bash
set -euo pipefail

# Ensure local bin and system bin paths are visible
export PATH="/root/.local/bin:/usr/local/bin:$PATH"

# 1. Validate required environment variables up front
if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
  echo "[start.sh] ERROR: DISCORD_BOT_TOKEN is not set. Hermes cannot connect to Discord. Aborting."
  exit 1
fi

# 2. Restore & clean GitHub Copilot Token
if [ -n "${COPILOT_TOKEN:-}" ]; then
  mkdir -p /root/.local/share/copilot-proxy-api
  mkdir -p /root/.local/share/copilot-api-proxy

  # Strip newlines/whitespace that break HTTP headers
  CLEAN_TOKEN=$(echo "$COPILOT_TOKEN" | tr -d '\r\n ')

  echo -n "$CLEAN_TOKEN" > /root/.local/share/copilot-proxy-api/github_token
  echo -n "$CLEAN_TOKEN" > /root/.local/share/copilot-api-proxy/github_token
  echo "[start.sh] Copilot token written."
else
  echo "[start.sh] WARNING: COPILOT_TOKEN is not set — proxy may fail to authenticate."
fi

# 3. Launch Copilot Proxy via PM2 with a restart backoff so a bad token
#    doesn't hammer the Copilot API with instant retries on crash.
# PM2 requires arguments after the binary to be passed with '--' so it treats
# them as process arguments, not additional pm2 flags.
pm2 start copilot-proxy-api \
  --name "copilot-proxy" \
  --restart-delay 5000 \
  -- start --port 9876

# Save the process list so PM2 can recover it after an unexpected restart.
pm2 save

# 4. Wait for the proxy to be ready on :9876 before starting Hermes.
#    Hermes tries to hit the proxy immediately on boot; if the proxy isn't
#    listening yet the first request fails and Hermes may crash-loop.
echo "[start.sh] Waiting for copilot-proxy to be ready on :9876..."
MAX_WAIT=30
ELAPSED=0
until curl -sf http://127.0.0.1:9876/ > /dev/null 2>&1; do
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "[start.sh] ERROR: copilot-proxy did not become ready within ${MAX_WAIT}s. Aborting."
    pm2 logs --nostream --lines 50
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
echo "[start.sh] copilot-proxy is ready (waited ${ELAPSED}s)."

# 5. Configure environment variables for Hermes
export OPENAI_BASE_URL="http://127.0.0.1:9876/v1"
export OPENAI_API_KEY="dummy-key"
export OPENAI_MODEL_NAME="gpt-4o"

# DISCORD_BOT_TOKEN and DISCORD_ALLOWED_USERS are already present in the
# environment from Render's secret env vars; no need to re-export them.
# The lines below are kept for explicitness but are no-ops if already set.
export DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
export DISCORD_ALLOWED_USERS="${DISCORD_ALLOWED_USERS:-}"

# 6. Launch Hermes Discord Gateway via PM2 with a restart backoff.
# 'hermes' must be on PATH (symlinked to /usr/local/bin/hermes in Dockerfile).
pm2 start hermes \
  --name "hermes-discord" \
  --restart-delay 5000 \
  -- gateway run

# Save updated process list (now includes hermes-discord).
pm2 save

# 7. Keep the container alive and stream logs.
echo "[start.sh] Both processes registered with PM2. Streaming logs..."
pm2 logs --raw