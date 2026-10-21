FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3 python3-pip git curl procps \
    && rm -rf /var/lib/apt/lists/*

# Install PM2 and copilot-proxy-api globally
RUN npm install -g pm2 copilot-proxy-api

WORKDIR /app

# Install Hermes Agent and symlink to global PATH so PM2 can execute it anywhere
RUN curl -fsSL https://raw.githubusercontent.com/hermes-agent/hermes-agent/main/scripts/install.sh | bash || true \
    && find / -name "hermes" -type f -executable 2>/dev/null | xargs -I {} cp {} /usr/local/bin/ || true

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

CMD ["/app/start.sh"]