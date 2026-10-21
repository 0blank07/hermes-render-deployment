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

# Initial default fallback model
export COPILOT_FALLBACK_MODEL="gpt-4o"

# 3. Launch Copilot Proxy via PM2 with a restart backoff so a bad token
#    doesn't hammer the Copilot API with instant retries on crash.
pm2 start copilot-proxy-api \
  --name "copilot-proxy" \
  --restart-delay 5000 \
  -- start --port 9876 --verbose

# Save the process list so PM2 can recover it after an unexpected restart.
pm2 save

# 4. Wait for the proxy to be ready on :9876 before starting Hermes.
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

# 5. Automatically probe copilot-proxy for available models and select a verified working model
mkdir -p /root/.hermes
python3 -c '
import urllib.request
import urllib.error
import json
import os
import re

config_path = "/root/.hermes/config.yaml"
env_path = "/root/.hermes/.env"

# 1. Fetch available models from proxy
model_ids = []
try:
    req = urllib.request.Request("http://127.0.0.1:9876/v1/models")
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
        model_ids = [m["id"] for m in data.get("data", [])]
        print(f"[start.sh] Copilot proxy reports {len(model_ids)} available models:")
        for mid in model_ids:
            print(f"  - {mid}")
except Exception as e:
    print(f"[start.sh] Could not list models: {e}")

# 2. Test candidate models to find which one works on this Copilot account
user_model = os.environ.get("HERMES_MODEL", "").strip()
priority = [
    "gpt-4o", "gpt-4o-mini", "claude-3.5-sonnet", "claude-3-5-sonnet-20241022",
    "gpt-4", "gpt-4-turbo", "o1-mini", "o3-mini", "gpt-3.5-turbo"
]
candidates = []
if user_model and user_model != "auto":
    candidates.append(user_model)
for p in priority:
    if p in model_ids and p not in candidates:
        candidates.append(p)
for mid in model_ids:
    if mid not in candidates:
        candidates.append(mid)

working_model = None
for candidate in candidates[:25]:
    try:
        payload = json.dumps({
            "model": candidate,
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 5
        }).encode("utf-8")
        req = urllib.request.Request(
            "http://127.0.0.1:9876/v1/chat/completions",
            data=payload,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                working_model = candidate
                print(f"[start.sh] >>> Verified working model on your Copilot account: {candidate} <<<")
                break
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", errors="ignore")
        print(f"[start.sh] Model \"{candidate}\" rejected (HTTP {err.code}): {body[:150]}")
    except Exception as e:
        print(f"[start.sh] Model \"{candidate}\" test error: {e}")

if not working_model:
    working_model = "gpt-4o"
    print(f"[start.sh] WARNING: No tested model succeeded. Defaulting to: {working_model}")

# Record working model for the shell
with open("/tmp/working_model.txt", "w") as f:
    f.write(working_model)

# 3. Configure /root/.hermes/config.yaml
providers_block = f"""
providers:
  copilot-proxy:
    base_url: "http://127.0.0.1:9876/v1"
    api_key: "dummy-key"
    api_mode: "chat_completions"
  custom:
    base_url: "http://127.0.0.1:9876/v1"
    api_key: "dummy-key"
    api_mode: "chat_completions"
"""

if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Update model.default
    if re.search(r"\nmodel:.*?\n\s+default:\s*[^\n]+", content, re.DOTALL):
        content = re.sub(r"(\nmodel:.*?\n\s+default:\s*)[^\n]+", rf"\g<1>\"{working_model}\"", content, count=1, flags=re.DOTALL)
    # Update model.provider
    if re.search(r"\nmodel:.*?\n\s+provider:\s*[^\n]+", content, re.DOTALL):
        content = re.sub(r"(\nmodel:.*?\n\s+provider:\s*)[^\n]+", r"\g<1>\"copilot-proxy\"", content, count=1, flags=re.DOTALL)
    # Update model.base_url
    if "base_url:" in content:
        content = re.sub(r"(\nmodel:.*?\n\s+base_url:\s*)[^\n]+", r"\g<1>\"http://127.0.0.1:9876/v1\"", content, count=1, flags=re.DOTALL)
    else:
        content = re.sub(r"(\nmodel:.*?\n\s+provider:\s*[^\n]+)", r"\g<1>\n  base_url: \"http://127.0.0.1:9876/v1\"", content, count=1, flags=re.DOTALL)

    # Remove any existing providers block and append the canonical one
    content = re.sub(r"\nproviders:.*?(?=\n[a-zA-Z_]|\Z)", "", content, flags=re.DOTALL)
    content = content.strip() + "\n" + providers_block.strip() + "\n"

    with open(config_path, "w", encoding="utf-8") as f:
        f.write(content)
else:
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f"""model:
  default: \"{working_model}\"
  provider: \"copilot-proxy\"
  base_url: \"http://127.0.0.1:9876/v1\"
{providers_block.strip()}
""")

# 4. Configure /root/.hermes/.env
with open(env_path, "w", encoding="utf-8") as f:
    f.write("""OPENAI_BASE_URL=http://127.0.0.1:9876/v1
OPENAI_API_KEY=dummy-key
CUSTOM_API_KEY=dummy-key
COPILOT_PROXY_API_KEY=dummy-key
""")

print(f"[start.sh] Successfully configured Hermes config.yaml and .env with model: \"{working_model}\"")
'

# Read detected working model and update environment
if [ -f /tmp/working_model.txt ]; then
  WORKING_MODEL=$(cat /tmp/working_model.txt)
else
  WORKING_MODEL="gpt-4o"
fi

export COPILOT_FALLBACK_MODEL="${WORKING_MODEL}"
export OPENAI_BASE_URL="http://127.0.0.1:9876/v1"
export OPENAI_API_KEY="dummy-key"
export CUSTOM_API_KEY="dummy-key"
export COPILOT_PROXY_API_KEY="dummy-key"

# Restart copilot-proxy so it receives the updated COPILOT_FALLBACK_MODEL
pm2 restart copilot-proxy --update-env

# Clear any previous broken session state so Hermes starts completely fresh
rm -rf /root/.hermes/sessions/* /root/.hermes/state.db* 2>/dev/null || true

# DISCORD_BOT_TOKEN and DISCORD_ALLOWED_USERS are already present in the environment
export DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
export DISCORD_ALLOWED_USERS="${DISCORD_ALLOWED_USERS:-}"

# Configure Web Dashboard authentication credentials.
export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-admin}"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-hermes123}"

# 6. Launch Hermes Discord Gateway via PM2 with a restart backoff.
pm2 start /usr/local/bin/hermes \
  --name "hermes-discord" \
  --interpreter bash \
  --restart-delay 5000 \
  -- gateway run

# 7. Launch Hermes Web Dashboard via PM2
DASHBOARD_PORT="${PORT:-10000}"
echo "[start.sh] Launching Hermes Web Dashboard on port ${DASHBOARD_PORT}..."
pm2 start /usr/local/bin/hermes \
  --name "hermes-dashboard" \
  --interpreter bash \
  --restart-delay 5000 \
  -- dashboard --host 0.0.0.0 --port "${DASHBOARD_PORT}" --no-open

# 8. Wait for dashboard to be ready on $DASHBOARD_PORT
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

# Save updated process list.
pm2 save

# 9. Keep the container alive and stream logs.
echo "[start.sh] All processes registered with PM2. Streaming logs..."
pm2 logs --raw
