FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-full git curl procps bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install PM2 and copilot-proxy-api globally
RUN npm install -g pm2 copilot-proxy-api

WORKDIR /app

# Install Hermes Agent from the official NousResearch repository.
# Passing --non-interactive prevents the installer from prompting on /dev/tty (which fails in Docker),
# and skipping browser/computer-use keeps the build lightweight.
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --non-interactive --skip-browser --skip-computer-use \
    && HERMES_BIN=$(find /root -name "hermes" -type f -executable 2>/dev/null | head -n1) \
    && if [ -z "$HERMES_BIN" ]; then echo "ERROR: hermes binary not found after install" && exit 1; fi \
    && ln -sf "$HERMES_BIN" /usr/local/bin/hermes \
    && echo "hermes installed at $HERMES_BIN -> /usr/local/bin/hermes"

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Use shell form so the shebang in start.sh is honoured and bash is guaranteed.
CMD ["/bin/bash", "/app/start.sh"]