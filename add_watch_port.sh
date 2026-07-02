#!/usr/bin/env bash
set -e

echo "Adding separate smooth Watch Port 7861..."

if [ ! -f server.js ]; then
  echo "ERROR: server.js not found."
  exit 1
fi

if [ ! -f public/index.html ]; then
  echo "ERROR: public/index.html not found."
  exit 1
fi

if [ ! -f public/app.js ]; then
  echo "ERROR: public/app.js not found."
  exit 1
fi

cp server.js "server.js.backup-watch-port-$(date +%s)"
cp public/index.html "public/index.html.backup-watch-port-$(date +%s)"
cp public/app.js "public/app.js.backup-watch-port-$(date +%s)"
cp start.sh "start.sh.backup-watch-port-$(date +%s)" 2>/dev/null || true

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let s = fs.readFileSync("server.js", "utf8");

// Add WATCH_PORT
if (!s.includes("const WATCH_PORT")) {
  s = s.replace(
    `const PORT = Number(process.env.PORT || 7860);`,
    `const PORT = Number(process.env.PORT || 7860);
const WATCH_PORT = Number(process.env.WATCH_PORT || 7861);`
  );
}

// Add watch app/server
if (!s.includes("const watchApp = express();")) {
  s = s.replace(
    `const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });`,
    `const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

const watchApp = express();
const watchServer = createServer(watchApp);
const watchWss = new WebSocketServer({ noServer: true });`
  );
}

// Add watch static serving
if (!s.includes("watchApp.use(express.static")) {
  s = s.replace(
    `app.use("/novnc", express.static("/usr/share/novnc", {
  etag: false,
  maxAge: 0
}));`,
    `app.use("/novnc", express.static("/usr/share/novnc", {
  etag: false,
  maxAge: 0
}));

watchApp.disable("x-powered-by");
watchApp.set("etag", false);

watchApp.use((req, res, next) => {
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
  res.setHeader("Pragma", "no-cache");
  res.setHeader("Expires", "0");
  res.setHeader("X-Content-Type-Options", "nosniff");
  next();
});

watchApp.get("/", (req, res) => {
  res.redirect("/watch.html");
});

watchApp.use(express.static(path.join(__dirname, "public"), {
  etag: false,
  maxAge: 0,
  setHeaders: (res) => res.setHeader("Cache-Control", "no-store")
}));

watchApp.use("/novnc", express.static("/usr/share/novnc", {
  etag: false,
  maxAge: 0
}));`
  );
}

// Add shared VNC bridge helper + watch server upgrade
if (!s.includes("function bridgeVncWebsocket")) {
  const bridgeCode = `
function bridgeVncWebsocket(ws) {
  const vnc = net.createConnection(VNC_PORT, "127.0.0.1");

  ws.on("message", (data) => {
    if (!vnc.destroyed) vnc.write(data);
  });

  vnc.on("data", (data) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(data);
  });

  const closeBoth = () => {
    try { ws.close(); } catch {}
    try { vnc.destroy(); } catch {}
  };

  ws.on("close", closeBoth);
  ws.on("error", closeBoth);
  vnc.on("close", closeBoth);
  vnc.on("error", closeBoth);
}

`;

  s = s.replace(`server.on("upgrade", (req, socket, head) => {`, bridgeCode + `server.on("upgrade", (req, socket, head) => {`);
}

// Simplify main upgrade to use helper if it still has old duplicate body
s = s.replace(
  /wss\.handleUpgrade\(req, socket, head, \(ws\) => \{\s*const vnc = net\.createConnection\(VNC_PORT, "127\.0\.0\.1"\);[\s\S]*?vnc\.on\("error", closeBoth\);\s*\}\);/,
  `wss.handleUpgrade(req, socket, head, (ws) => {
    bridgeVncWebsocket(ws);
  });`
);

// Add watch server upgrade
if (!s.includes("watchServer.on(\"upgrade\"")) {
  s = s.replace(
    `app.post("/api/navigate", async (req, res) => {`,
    `watchServer.on("upgrade", (req, socket, head) => {
  if (!req.url.startsWith("/websockify")) {
    socket.destroy();
    return;
  }

  watchWss.handleUpgrade(req, socket, head, (ws) => {
    bridgeVncWebsocket(ws);
  });
});

app.post("/api/navigate", async (req, res) => {`
  );
}

// Add watch mode endpoint
if (!s.includes(`app.post("/api/watch-mode"`)) {
  const endpoint = `
app.post("/api/watch-mode", async (req, res) => {
  try {
    await configureGermanyAndTouch();

    let info = {};

    try {
      const result = await cdp("Runtime.evaluate", {
        expression: \`
(() => {
  const video = document.querySelector("video");

  if (video) {
    try { video.play(); } catch {}
  }

  const host = String(location.hostname || "").toLowerCase();
  const isYouTube =
    host === "youtube.com" ||
    host.endsWith(".youtube.com") ||
    host === "youtu.be" ||
    host.endsWith(".youtu.be");

  if (isYouTube) {
    try {
      const player = document.querySelector("#movie_player");
      if (player?.setPlaybackQualityRange) player.setPlaybackQualityRange("small", "medium");
      if (player?.setPlaybackQuality) player.setPlaybackQuality("small");
    } catch {}

    try {
      document.body.style.cursor = "none";
    } catch {}
  }

  return {
    href: location.href,
    title: document.title,
    isYouTube,
    hasVideo: Boolean(video)
  };
})()
\`,
        returnByValue: true,
        awaitPromise: true
      });

      info = result?.result?.value || {};
    } catch {}

    res.json({
      ok: true,
      watchPort: WATCH_PORT,
      info
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

`;

  s = s.replace(`app.post("/api/text"`, endpoint + `app.post("/api/text"`);
}

// Start watch server
if (!s.includes("watchServer.listen(WATCH_PORT")) {
  s = s.replace(
    `server.listen(PORT, "0.0.0.0", () => {`,
    `watchServer.listen(WATCH_PORT, "0.0.0.0", () => {
  console.log(\` Watch-only port running on: \${WATCH_PORT}\`);
});

server.listen(PORT, "0.0.0.0", () => {`
  );
}

// Update console text
s = s.replace(
  `console.log(\` Open Codespaces port: \${PORT}\`);`,
  `console.log(\` Open Codespaces main port: \${PORT}\`);
  console.log(\` Open Codespaces watch port: \${WATCH_PORT}\`);`
);

fs.writeFileSync("server.js", s);
NODE

cat > public/watch.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Watch Port</title>
  <style>
    html,
    body,
    #screen {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #000;
      touch-action: none;
      overscroll-behavior: none;
    }

    body {
      position: fixed;
      inset: 0;
    }

    #screen {
      position: absolute;
      inset: 0;
    }

    #status {
      position: fixed;
      left: 14px;
      top: 14px;
      z-index: 10;
      padding: 9px 12px;
      border-radius: 999px;
      background: rgba(0,0,0,.58);
      color: white;
      font: 12px system-ui, sans-serif;
      pointer-events: none;
      opacity: 1;
      transition: opacity .4s ease;
    }

    #status.hide {
      opacity: 0;
    }
  </style>
</head>
<body>
  <div id="screen"></div>
  <div id="status">Watch-only mode: connecting...</div>

  <script type="module">
    import RFB from "/novnc/core/rfb.js";

    const screen = document.getElementById("screen");
    const status = document.getElementById("status");

    function setStatus(text, hide = false) {
      status.textContent = text;
      status.classList.remove("hide");

      if (hide) {
        clearTimeout(setStatus.timer);
        setStatus.timer = setTimeout(() => {
          status.classList.add("hide");
        }, 1800);
      }
    }

    const protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const url = `${protocol}//${location.host}/websockify`;

    const rfb = new RFB(screen, url, {
      shared: true,
      credentials: {}
    });

    rfb.scaleViewport = true;
    rfb.resizeSession = true;
    rfb.clipViewport = false;
    rfb.dragViewport = false;
    rfb.viewOnly = true;
    rfb.qualityLevel = 5;
    rfb.compressionLevel = 9;
    rfb.showDotCursor = false;

    rfb.addEventListener("connect", () => {
      setStatus("Watch-only connected. Input disabled for smoother viewing.", true);
    });

    rfb.addEventListener("disconnect", () => {
      setStatus("Disconnected. Refresh this tab or restart the browser.");
    });

    document.addEventListener("touchmove", (e) => e.preventDefault(), { passive: false });
    document.addEventListener("gesturestart", (e) => e.preventDefault(), { passive: false });
    document.addEventListener("gesturechange", (e) => e.preventDefault(), { passive: false });
    document.addEventListener("gestureend", (e) => e.preventDefault(), { passive: false });
    document.addEventListener("contextmenu", (e) => e.preventDefault());
  </script>
</body>
</html>
EOF

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let html = fs.readFileSync("public/index.html", "utf8");

if (!html.includes('id="watchPortBtn"')) {
  html = html.replace(
    `<button id="saveBtn">Save</button>`,
    `<button id="saveBtn">Save</button>
      <button id="watchPortBtn">Watch Port</button>`
  );

  if (!html.includes('id="watchPortBtn"')) {
    html = html.replace(
      `<button id="keyboardBtn">Keyboard</button>`,
      `<button id="keyboardBtn">Keyboard</button>
      <button id="watchPortBtn">Watch Port</button>`
    );
  }
}

fs.writeFileSync("public/index.html", html);
NODE

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let js = fs.readFileSync("public/app.js", "utf8");

if (!js.includes('document.getElementById("watchPortBtn")')) {
  const code = `
function getWatchPortUrl() {
  const host = location.host;

  if (/-\\d+\\./.test(host)) {
    return location.protocol + "//" + host.replace(/-\\d+\\./, "-7861.") + "/watch.html";
  }

  if (/:\\d+$/.test(host)) {
    return location.protocol + "//" + host.replace(/:\\d+$/, ":7861") + "/watch.html";
  }

  return location.protocol + "//" + location.hostname + ":7861/watch.html";
}

const watchPortBtn = document.getElementById("watchPortBtn");

if (watchPortBtn) {
  watchPortBtn.onclick = async () => {
    try {
      toast("Preparing watch-only port...");
      await postJson("/api/watch-mode", {});

      const url = getWatchPortUrl();
      window.open(url, "_blank", "noopener,noreferrer");

      toast("Opened Watch Port 7861");
      console.log("Watch Port URL:", url);
    } catch (error) {
      toast(error.message || "Watch Port failed.");
    }
  };
}

`;

  js = js.replace(
    `const saveBtn = document.getElementById("saveBtn");`,
    code + `const saveBtn = document.getElementById("saveBtn");`
  );

  if (!js.includes('document.getElementById("watchPortBtn")')) {
    js += code;
  }
}

fs.writeFileSync("public/app.js", js);
NODE

# Update start.sh to print and start watch port
if [ -f start.sh ]; then
  node --input-type=commonjs <<'NODE'
const fs = require("fs");

let sh = fs.readFileSync("start.sh", "utf8");

if (!sh.includes('WATCH_PORT="${WATCH_PORT:-7861}"')) {
  sh = sh.replace(
    `PORT="\${PORT:-7860}"`,
    `PORT="\${PORT:-7860}"
WATCH_PORT="\${WATCH_PORT:-7861}"`
  );
}

if (!sh.includes('Watch Port: $WATCH_PORT')) {
  sh = sh.replace(
    `echo " Port: $PORT"`,
    `echo " Main Port: $PORT"
echo " Watch Port: $WATCH_PORT"`
  );
}

if (!sh.includes('${CODESPACE_NAME}-${WATCH_PORT}')) {
  sh = sh.replace(
    `echo "https://\${CODESPACE_NAME}-\${PORT}.\${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/"`,
    `echo "Main:"
  echo "https://\${CODESPACE_NAME}-\${PORT}.\${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/"
  echo "Watch-only:"
  echo "https://\${CODESPACE_NAME}-\${WATCH_PORT}.\${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/watch.html"`
  );
}

sh = sh.replace(
  `PORT="$PORT" npm start`,
  `PORT="$PORT" WATCH_PORT="$WATCH_PORT" npm start`
);

fs.writeFileSync("start.sh", sh);
NODE

  chmod +x start.sh
fi

# Update devcontainer ports
if [ -f .devcontainer/devcontainer.json ]; then
  node --input-type=commonjs <<'NODE'
const fs = require("fs");

const p = ".devcontainer/devcontainer.json";
let raw = fs.readFileSync(p, "utf8");

try {
  const json = JSON.parse(raw);

  json.forwardPorts = Array.from(new Set([...(json.forwardPorts || []), 7860, 7861]));

  json.portsAttributes = json.portsAttributes || {};
  json.portsAttributes["7861"] = {
    label: "Watch-only Browser",
    onAutoForward: "silent"
  };

  fs.writeFileSync(p, JSON.stringify(json, null, 2));
} catch {
  if (!raw.includes("7861")) {
    raw = raw.replace(`[7860]`, `[7860, 7861]`);
    fs.writeFileSync(p, raw);
  }
}
NODE
fi

echo ""
echo "===================================================="
echo "Watch Port added."
echo ""
echo "Main browser: 7860"
echo "Watch-only screen: 7861"
echo ""
echo "Use it like this:"
echo "1. Open YouTube/video on port 7860."
echo "2. Start the video."
echo "3. Press the new 'Watch Port' button."
echo "4. Watch the clean view on port 7861."
echo ""
echo "Port 7861 is view-only, so no touch/keyboard overlay is active there."
echo "===================================================="
echo ""

if [ -x ./start.sh ]; then
  ./start.sh
else
  PORT=7860 WATCH_PORT=7861 npm start
fi
