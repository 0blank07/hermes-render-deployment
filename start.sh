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
        model_ids = [m["id"].strip("\"'\''") for m in data.get("data", []) if "id" in m]
        print(f"[start.sh] Copilot proxy reports {len(model_ids)} available models:")
        for mid in model_ids:
            print(f"  - {mid}")
except Exception as e:
    print(f"[start.sh] Could not list models: {e}")

# 2. Test candidate models in hierarchy order (Flagship -> Advanced -> Balanced -> Lightweight)
user_model = os.environ.get("HERMES_MODEL", "").strip().strip("\"'\''")
priority = [
    # Tier 1: Flagship / Best (GPT-4o & top variants)
    "gpt-4o",
    "gpt-4o-2024-11-20",
    "gpt-4o-2024-08-06",
    "gpt-4o-2024-05-13",
    "gpt-4-o-preview",
    "claude-3.5-sonnet",
    "claude-3-5-sonnet-20241022",
    "claude-sonnet-5",
    "claude-sonnet-5.5",
    "gpt-4.1",
    "gpt-4.1-2025-04-14",
    "gpt-4",
    "gpt-4-0613",
    "gpt-4-0125-preview",
    # Tier 2: Deep Reasoning
    "o3-mini",
    "o1-mini",
    # Tier 3: Balanced & High Rate Limits (Fast fallbacks)
    "gpt-4o-mini",
    "gpt-4o-mini-2024-07-18",
    "claude-haiku-4.5",
    "claude-haiku-5.5",
    "gemini-3.8-flash",
    "mai-code-1.1-flash",
    "gpt-3.5-turbo",
    "gpt-3.5-turbo-0613"
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

verified_models = []
print(f"[start.sh] Probing candidate models for HTTP 200 OK (Best -> Balanced)...")
for candidate in candidates[:25]:
    try:
        payload = json.dumps({
            "model": candidate,
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 1
        }).encode("utf-8")
        req = urllib.request.Request(
            "http://127.0.0.1:9876/v1/chat/completions",
            data=payload,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            if resp.status == 200:
                verified_models.append(candidate)
                print(f"[start.sh]   [✓] 200 OK: \"{candidate}\"")
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", errors="ignore")
        print(f"[start.sh]   [✗] HTTP {err.code}: \"{candidate}\"")
    except Exception as e:
        print(f"[start.sh]   [✗] Error: \"{candidate}\" ({e})")

if verified_models:
    primary_model = verified_models[0].strip("\"'\''")
    fallback_models = [m.strip("\"'\''") for m in verified_models[1:]]
else:
    primary_model = "gpt-4o"
    fallback_models = ["gpt-4o-mini"]
    print("[start.sh] WARNING: No tested model succeeded. Defaulting to: gpt-4o with gpt-4o-mini fallback")

print("\n[start.sh] ===================================================")
print(f"[start.sh] Primary Model (Best): {primary_model}")
if fallback_models:
    print(f"[start.sh] Dynamic Fallback Chain ({len(fallback_models)} verified backups):")
    for idx, bm in enumerate(fallback_models, 1):
        print(f"[start.sh]   {idx}. {bm}")
else:
    print("[start.sh] No additional backup models detected.")
print("[start.sh] ===================================================\n")

# Record primary model for the shell
with open("/tmp/working_model.txt", "w") as f:
    f.write(primary_model)

# 3. Configure /root/.hermes/config.yaml with dynamic fallback chain
fallback_lines = []
if fallback_models:
    fallback_lines.append("fallback_providers:")
    for m in fallback_models:
        fallback_lines.append(f"  - provider: copilot-proxy\n    model: {m}")
fallback_block = "\n".join(fallback_lines)

providers_block = f"""
agent:
  api_max_retries: 1

{fallback_block}

providers:
  copilot-proxy:
    base_url: http://127.0.0.1:9876/v1
    api_key: dummy-key
    api_mode: chat_completions
  custom:
    base_url: http://127.0.0.1:9876/v1
    api_key: dummy-key
    api_mode: chat_completions

auxiliary:
  compression:
    provider: copilot-proxy
  vision:
    provider: copilot-proxy
  title:
    provider: copilot-proxy
"""

if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Update model.default  (clean scalar, no quotes)
    if re.search(r"(\nmodel:.*?\n\s+default:\s*)[^\n]+", content, re.DOTALL):
        content = re.sub(r"(\nmodel:.*?\n\s+default:\s*)[^\n]+", rf"\g<1>{primary_model}", content, count=1, flags=re.DOTALL)
    # Update model.provider (clean scalar, no quotes)
    if re.search(r"(\nmodel:.*?\n\s+provider:\s*)[^\n]+", content, re.DOTALL):
        content = re.sub(r"(\nmodel:.*?\n\s+provider:\s*)[^\n]+", r"\g<1>copilot-proxy", content, count=1, flags=re.DOTALL)
    # Update model.base_url
    if "base_url:" in content:
        content = re.sub(r"(\nmodel:.*?\n\s+base_url:\s*)[^\n]+", r"\g<1>http://127.0.0.1:9876/v1", content, count=1, flags=re.DOTALL)
    else:
        content = re.sub(r"(\nmodel:.*?\n\s+provider:\s*[^\n]+)", r"\g<1>\n  base_url: http://127.0.0.1:9876/v1", content, count=1, flags=re.DOTALL)

    # Remove any existing agent, fallback_providers, providers, or auxiliary blocks and append canonical ones
    content = re.sub(r"\nagent:.*?(?=\n[a-zA-Z_]|\Z)", "", content, flags=re.DOTALL)
    content = re.sub(r"\nfallback_providers:.*?(?=\n[a-zA-Z_]|\Z)", "", content, flags=re.DOTALL)
    content = re.sub(r"\nproviders:.*?(?=\n[a-zA-Z_]|\Z)", "", content, flags=re.DOTALL)
    content = re.sub(r"\nauxiliary:.*?(?=\n[a-zA-Z_]|\Z)", "", content, flags=re.DOTALL)
    content = content.strip() + "\n" + providers_block.strip() + "\n"

    with open(config_path, "w", encoding="utf-8") as f:
        f.write(content)
else:
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(f"""model:
  default: {primary_model}
  provider: copilot-proxy
  base_url: http://127.0.0.1:9876/v1
{providers_block.strip()}
""")

# 4. Configure /root/.hermes/.env
discord_token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
allowed_users = os.environ.get("DISCORD_ALLOWED_USERS", "").strip() or "*"

with open(env_path, "w", encoding="utf-8") as f:
    f.write(f"""OPENAI_BASE_URL=http://127.0.0.1:9876/v1
OPENAI_API_KEY=dummy-key
CUSTOM_API_KEY=dummy-key
COPILOT_PROXY_API_KEY=dummy-key
DISCORD_BOT_TOKEN={discord_token}
DISCORD_ALLOWED_USERS={allowed_users}
""")

print(f"[start.sh] Successfully configured Hermes config.yaml and .env with model: {working_model}")
'

# Read detected working model and update environment
if [ -f /tmp/working_model.txt ]; then
  WORKING_MODEL=$(cat /tmp/working_model.txt | tr -d '\"'\''')
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

# Export Discord bot configuration (default to allowing all users if unset)
export DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
export DISCORD_ALLOWED_USERS="${DISCORD_ALLOWED_USERS:-*}"

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
