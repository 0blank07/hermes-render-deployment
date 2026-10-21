FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-full git curl procps bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install PM2 and copilot-proxy-api globally
RUN npm install -g pm2 copilot-proxy-api

# Apply auto/fallback model resilience patch to copilot-proxy-api so requests for 'auto',
# unmapped models, or quoted models are smoothly translated to the active working model instead of failing with HTTP 400.
RUN node -e '\
const fs = require("fs"); \
const path = require("path"); \
const { execSync } = require("child_process"); \
const globalDir = execSync("npm root -g", { encoding: "utf8" }).trim(); \
const p = path.join(globalDir, "copilot-proxy-api", "dist", "main.mjs"); \
let code = fs.readFileSync(p, "utf8"); \
code = code.replace("s=JSON.stringify(n);", "s=JSON.stringify((()=>{let m=typeof n.model===\"string\"?n.model.replace(/[\\x27\\x22\\x5C]/g,\"\"):n.model;if(!m||m===\"auto\"||m===\"opus 4.6\"||m.includes(\"opus-4.6\")){m=process.env.COPILOT_FALLBACK_MODEL||\"gpt-4o\"}return {...n,model:m}})());"); \
fs.writeFileSync(p, code); \
console.log("[Dockerfile] Patched copilot-proxy-api for auto model fallback."); \
'

WORKDIR /app

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
