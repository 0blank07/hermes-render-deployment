const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const globalDir = execSync("npm root -g", { encoding: "utf8" }).trim();
const p = path.join(globalDir, "copilot-proxy-api", "dist", "main.mjs");

if (!fs.existsSync(p)) {
  console.error("[patch-proxy.js] Error: copilot-proxy-api not found at", p);
  process.exit(1);
}

let code = fs.readFileSync(p, "utf8");

// 1. Model sanitization, fallback translation, and reasoning_effort stripping
code = code.replace(
  "s=JSON.stringify(n);",
  "s=JSON.stringify((()=>{let m=typeof n.model===\"string\"?n.model.replace(/[\\x27\\x22\\x5C]/g,\"\"):n.model;if(!m||m===\"auto\"||m===\"opus 4.6\"||m.includes(\"opus-4.6\")){m=process.env.COPILOT_FALLBACK_MODEL||\"gpt-4o\"}const out={...n,model:m};if(out.reasoning_effort&&!/^o[13]/.test(m)){delete out.reasoning_effort;}return out;})());"
);

// 2. Transparent retry with gpt-4o-mini on HTTP 429
code = code.replace(
  "if(!c.ok){let e=await c.text();",
  "if(c.status===429&&n.model!==\"gpt-4o-mini\"){n.model=\"gpt-4o-mini\";delete n.reasoning_effort;s=JSON.stringify(n);try{c=await F(`${v(g)}/chat/completions`,{method:\"POST\",headers:o,body:s});}catch(err){}}if(!c.ok){let e=await c.text();"
);

// 3. Bind strictly to 127.0.0.1
code = code.replace("port:e.port", "port:e.port,hostname:\"127.0.0.1\"");

fs.writeFileSync(p, code);
console.log("[patch-proxy.js] Successfully patched copilot-proxy-api.");
