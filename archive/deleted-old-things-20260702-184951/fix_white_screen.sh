#!/usr/bin/env bash
set -e

echo "Fixing white screen issue..."
echo "Reason: port 5900 is raw VNC, not the browser UI."

pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
pkill -f "x11vnc" 2>/dev/null || true
sleep 1

if [ ! -f server.js ]; then
  echo "ERROR: server.js not found. Run the big Real JS Browser setup first."
  exit 1
fi

node <<'NODE'
const fs = require("fs");

let s = fs.readFileSync("server.js", "utf8");

// Move real VNC away from 5900 so opening 5900 does not show a white raw VNC page.
s = s.replace(/const VNC_PORT\s*=\s*\d+;/, "const VNC_PORT = 45991;");
s = s.replace(/const CDP_PORT\s*=\s*\d+;/, "const CDP_PORT = 45992;");

// Add a helper web page on port 5900, so if Codespaces opens 5900 by mistake,
// it redirects/explains instead of showing a white screen.
if (!s.includes("WRONG_PORT_HELPER_5900")) {
  const helper = `
const WRONG_PORT_HELPER_5900 = createServer((req, res) => {
  const host = req.headers.host || "";
  let targetHost = host;

  if (host.includes("-5900.")) {
    targetHost = host.replace("-5900.", "-7860.");
  } else if (host.includes(":5900")) {
    targetHost = host.replace(":5900", ":7860");
  }

  const isLocal = host.includes("localhost") || host.startsWith("127.");
  const proto = isLocal ? "http" : "https";
  const target = \`\${proto}://\${targetHost}/\`;

  res.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store"
  });

  res.end(\`<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Wrong Port</title>
<style>
  :root { color-scheme: dark; }
  body {
    margin: 0;
    min-height: 100vh;
    display: grid;
    place-items: center;
    background:
      radial-gradient(circle at top left, rgba(124,92,255,.35), transparent 35%),
      radial-gradient(circle at bottom right, rgba(0,212,255,.22), transparent 35%),
      #070913;
    color: white;
    font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  main {
    width: min(720px, calc(100vw - 40px));
    padding: 34px;
    border: 1px solid rgba(255,255,255,.14);
    border-radius: 28px;
    background: rgba(18,23,38,.82);
    box-shadow: 0 28px 90px rgba(0,0,0,.45);
  }
  h1 {
    margin: 0;
    font-size: clamp(34px, 6vw, 64px);
    line-height: .95;
    letter-spacing: -.06em;
    background: linear-gradient(135deg, white, #a9b3ff, #00d4ff);
    -webkit-background-clip: text;
    color: transparent;
  }
  p {
    color: #aeb7d4;
    line-height: 1.6;
    font-size: 17px;
  }
  a {
    display: inline-flex;
    margin-top: 12px;
    padding: 13px 18px;
    border-radius: 16px;
    color: white;
    font-weight: 850;
    text-decoration: none;
    background: linear-gradient(135deg, #7c5cff, #00d4ff);
  }
</style>
<script>
  setTimeout(() => {
    location.href = \${JSON.stringify(target)};
  }, 900);
</script>
</head>
<body>
<main>
  <h1>Wrong port opened.</h1>
  <p>
    Port 5900 is not the browser UI. It was the raw VNC port, which causes the white screen.
    Open the Codespaces browser app on port <strong>7860</strong>.
  </p>
  <a href="\${target}">Open correct browser port 7860</a>
</main>
</body>
</html>\`);
});

WRONG_PORT_HELPER_5900.listen(5900, "0.0.0.0", () => {
  console.log("Port 5900 helper is active. If opened, it redirects to 7860.");
});
`;

  s = s.replace(
    /server\.listen\(PORT,\s*"0\.0\.0\.0",\s*\(\)\s*=>\s*\{/,
    helper + "\nserver.listen(PORT, \"0.0.0.0\", () => {"
  );
}

fs.writeFileSync("server.js", s);
NODE

mkdir -p .devcontainer

cat > .devcontainer/devcontainer.json <<'EOF'
{
  "name": "Real JS Codespace Browser",
  "image": "mcr.microsoft.com/devcontainers/javascript-node:1-22-bookworm",
  "postCreateCommand": "npm install --no-package-lock",
  "forwardPorts": [7860],
  "portsAttributes": {
    "7860": {
      "label": "Real JS Browser",
      "onAutoForward": "openBrowser"
    },
    "5900": {
      "label": "Wrong Port Helper - use 7860"
    }
  },
  "otherPortsAttributes": {
    "onAutoForward": "silent"
  },
  "customizations": {
    "vscode": {
      "settings": {
        "terminal.integrated.enablePersistentSessions": false,
        "terminal.integrated.persistentSessionReviveProcess": "never"
      }
    }
  }
}
EOF

npm install --no-package-lock

echo ""
echo "===================================================="
echo "Fixed."
echo ""
echo "IMPORTANT:"
echo "Open Codespaces port 7860, not 5900."
echo ""
echo "5900 was the raw VNC port and caused the white screen."
echo "Now 5900 will show a helper page / redirect instead."
echo "===================================================="
echo ""

npm start
