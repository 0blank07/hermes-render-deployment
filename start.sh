#!/bin/bash

# Restore GitHub Copilot Token if passed as environment variable
if [ -n "$COPILOT_TOKEN" ]; then
  mkdir -p ~/.local/share/copilot-api-proxy
  echo "$COPILOT_TOKEN" > ~/.local/share/copilot-api-proxy/github_token
fi

# 1. Start the Copilot Proxy locally on port 9876 via PM2
pm2 start "copilot-api-proxy server --port 9876" --name "copilot-proxy"

# 2. Configure model base URL for Hermes Agent
export OPENAI_BASE_URL="http://127.0.0.1:9876/v1"
export OPENAI_API_KEY="dummy-key"
export OPENAI_MODEL_NAME="gpt-4o"

# 3. Start Hermes Discord Gateway
pm2 start "hermes gateway run" --name "hermes-discord"

# Stream logs continuously to Render
pm2 logs
