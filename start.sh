#!/bin/bash

# Ensure local bin and system bin paths are visible
export PATH="/root/.local/bin:/usr/local/bin:$PATH"

# 1. Restore & clean GitHub Copilot Token
if [ -n "$COPILOT_TOKEN" ]; then
  mkdir -p /root/.local/share/copilot-proxy-api
  mkdir -p /root/.local/share/copilot-api-proxy

  # Strip newlines/whitespace that break HTTP headers
  CLEAN_TOKEN=$(echo "$COPILOT_TOKEN" | tr -d '\r\n ')

  echo -n "$CLEAN_TOKEN" > /root/.local/share/copilot-proxy-api/github_token
  echo -n "$CLEAN_TOKEN" > /root/.local/share/copilot-api-proxy/github_token
fi

# 2. Launch Copilot Proxy via PM2
pm2 start "copilot-proxy-api server --port 9876" --name "copilot-proxy"

# 3. Configure environment variables for Hermes
export OPENAI_BASE_URL="http://127.0.0.1:9876/v1"
export OPENAI_API_KEY="dummy-key"
export OPENAI_MODEL_NAME="gpt-4o"

export DISCORD_BOT_TOKEN="$DISCORD_BOT_TOKEN"
export DISCORD_ALLOWED_USERS="$DISCORD_ALLOWED_USERS"

# 4. Launch Hermes Discord Gateway via PM2
pm2 start "hermes gateway run" --name "hermes-discord"

# Keep container open and stream logs
pm2 logs