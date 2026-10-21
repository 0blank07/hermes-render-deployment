FROM node:20-slim

# Install system dependencies
# Note: python3-pip is no longer a separate package on Debian Bookworm slim;
# python3-full provides pip via the venv/ensurepip path. Using --no-install-recommends
# keeps the image lean.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-full git curl procps bash \
    && rm -rf /var/lib/apt/lists/*

# Install PM2 and copilot-proxy-api globally
RUN npm install -g pm2 copilot-proxy-api

WORKDIR /app

# Install Hermes Agent.
# The installer may place the binary under ~/.local/bin or a tool-specific path.
# We search common locations and hard-link it to /usr/local/bin/hermes so PM2
# can resolve it regardless of PATH.  A failed install is surfaced (no || true on
# the install step) so the build fails fast instead of producing a broken image.
RUN curl -fsSL https://raw.githubusercontent.com/hermes-agent/hermes-agent/main/scripts/install.sh | bash \
    && HERMES_BIN=$(find /root /usr/local -name "hermes" -type f -executable 2>/dev/null | head -n1) \
    && if [ -z "$HERMES_BIN" ]; then echo "ERROR: hermes binary not found after install" && exit 1; fi \
    && ln -sf "$HERMES_BIN" /usr/local/bin/hermes \
    && echo "hermes installed at $HERMES_BIN -> /usr/local/bin/hermes"

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Use shell form so the shebang in start.sh is honoured and bash is guaranteed.
CMD ["/bin/bash", "/app/start.sh"]