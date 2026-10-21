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

# Configure Web Dashboard authentication credentials.
# Binding to 0.0.0.0 requires basic authentication. You can optionally customize
# HERMES_DASHBOARD_BASIC_AUTH_PASSWORD in Render's environment variables.
export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-admin}"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-hermes123}"

# 6. Launch Hermes Discord Gateway via PM2 with a restart backoff.
# 'hermes' must be on PATH (symlinked to /usr/local/bin/hermes in Dockerfile).
pm2 start /usr/local/bin/hermes \
  --name "hermes-discord" \
  --interpreter bash \
  --restart-delay 5000 \
  -- gateway run

# 7. Launch Hermes Web Dashboard via PM2
# Render automatically routes external HTTPS traffic to the port in $PORT (default 10000).
DASHBOARD_PORT="${PORT:-10000}"
echo "[start.sh] Launching Hermes Web Dashboard on port ${DASHBOARD_PORT}..."
pm2 start /usr/local/bin/hermes \
  --name "hermes-dashboard" \
  --interpreter bash \
  --restart-delay 5000 \
  -- dashboard --host 0.0.0.0 --port "${DASHBOARD_PORT}" --no-open

# 8. Wait for dashboard to be ready on $DASHBOARD_PORT so Render immediately detects it as primary
echo "[start.sh] Waiting for hermes-dashboard to be ready on port ${DASHBOARD_PORT}..."
MAX_WAIT_DASHBOARD=30
ELAPSED_DASHBOARD=0
until curl -sf "http://127.0.0.1:${DASHBOARD_PORT}/" > /dev/null 2>&1; do
  if [ "$ELAPSED_DASHBOARD" -ge "$MAX_WAIT_DASHBOARD" ]; then
    echo "[start.sh] WARNING: hermes-dashboard took longer than ${MAX_WAIT_DASHBOARD}s to start."
    break
  fi
  sleep 1
  ELAPSED_DASHBOARD=$((ELAPSED_DASHBOARD + 1))
done
if [ "$ELAPSED_DASHBOARD" -lt "$MAX_WAIT_DASHBOARD" ]; then
  echo "[start.sh] hermes-dashboard is ready on port ${DASHBOARD_PORT} (waited ${ELAPSED_DASHBOARD}s)."
fi

# Save updated process list (now includes hermes-discord and hermes-dashboard).
pm2 save

# 9. Keep the container alive and stream logs.
echo "[start.sh] All processes registered with PM2. Streaming logs..."
pm2 logs --raw