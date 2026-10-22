FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-full git curl procps bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install PM2 and copilot-proxy-api globally
RUN npm install -g pm2 copilot-proxy-api

WORKDIR /app

# Apply resilience patches to copilot-proxy-api via standalone patch script:
# 1. Map 'auto' or unmapped models to COPILOT_FALLBACK_MODEL
# 2. Strip unsupported 'reasoning_effort' parameter for non-o1/o3 models to prevent HTTP 400 errors
# 3. Transparently retry with gpt-4o-mini on HTTP 429 rate limit errors
# 4. Bind strictly to 127.0.0.1 so Render never mistakes port 9876 for the public web dashboard
COPY patch-proxy.js /app/patch-proxy.js
RUN node /app/patch-proxy.js

# Install Hermes Agent from the official NousResearch repository
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --non-interactive --skip-browser --skip-computer-use \
    && if [ ! -f /root/.local/bin/hermes ]; then echo "ERROR: /root/.local/bin/hermes not found after install" && exit 1; fi

# Create /usr/local/bin/hermes wrapper that cleanses PM2's leaked IPC file descriptors (NODE_CHANNEL_FD).
# Without unsetting these, child Node processes spawned by Hermes crash with SIGABRT: 6 (errno == EEXIST).
RUN printf '#!/bin/bash\nunset NODE_CHANNEL_FD\nunset NODE_CHANNEL_SERIALIZATION_MODE\nexec /root/.local/bin/hermes "$@"\n' > /usr/local/bin/hermes \
    && chmod +x /usr/local/bin/hermes

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Inform Render of the primary web port
ENV PORT=10000
EXPOSE 10000

# Use shell form so the shebang in start.sh is honoured and bash is guaranteed.
CMD ["/bin/bash", "/app/start.sh"]
