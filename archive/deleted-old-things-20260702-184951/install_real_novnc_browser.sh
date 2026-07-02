#!/usr/bin/env bash
set -e

echo "Replacing bad CDP canvas renderer with real noVNC Chromium screen..."

pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
pkill -f "x11vnc" 2>/dev/null || true
pkill -f "websockify" 2>/dev/null || true
sleep 1

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  chromium \
  xvfb \
  fluxbox \
  x11vnc \
  novnc \
  ca-certificates \
  fonts-liberation \
  fonts-noto-color-emoji \
  dbus-x11 \
  xdg-utils

rm -rf public node_modules package-lock.json server.js package.json .devcontainer .gitignore
mkdir -p public .devcontainer

cat > package.json <<'EOF'
{
  "name": "codespace-real-novnc-browser",
  "version": "5.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "ws": "^8.18.0"
  }
}
EOF

cat > server.js <<'EOF'
import express from "express";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import net from "node:net";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { WebSocketServer, WebSocket } from "ws";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PORT = Number(process.env.PORT || 7860);
const DISPLAY_NUM = ":99";
const VNC_PORT = 45991;
const CDP_PORT = 45992;

const GERMANY = {
  locale: "de-DE",
  acceptLanguage: "de-DE,de;q=0.9,en-US;q=0.6,en;q=0.5",
  timezone: "Europe/Berlin",
  latitude: 52.520008,
  longitude: 13.404954,
  accuracy: 50
};

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

let tempRoot = null;
let children = [];

app.disable("x-powered-by");
app.set("etag", false);
app.use(express.json({ limit: "1mb" }));

app.use((req, res, next) => {
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
  res.setHeader("Pragma", "no-cache");
  res.setHeader("Expires", "0");
  res.setHeader("X-Content-Type-Options", "nosniff");
  next();
});

app.use(express.static(path.join(__dirname, "public"), {
  etag: false,
  maxAge: 0,
  setHeaders: (res) => res.setHeader("Cache-Control", "no-store")
}));

app.use("/novnc", express.static("/usr/share/novnc", {
  etag: false,
  maxAge: 0
}));

function clean(value = "") {
  return String(value).replace(/\s+/g, " ").trim();
}

function normalizeUrl(raw) {
  const value = clean(raw);
  if (!value) throw new Error("Empty URL.");
  if (value.startsWith("http://") || value.startsWith("https://")) return value;
  return `https://${value}`;
}

function commandExists(name) {
  return (process.env.PATH || "")
    .split(":")
    .some((p) => fs.existsSync(path.join(p, name)));
}

function findChromium() {
  for (const name of ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]) {
    if (commandExists(name)) return name;
  }
  return null;
}

function spawnChild(cmd, args, env = {}) {
  const child = spawn(cmd, args, {
    stdio: "ignore",
    env: {
      ...process.env,
      ...env
    }
  });

  children.push(child);
  return child;
}

async function waitForCdp(retries = 50) {
  for (let i = 0; i < retries; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
      const targets = await r.json();
      const page =
        targets.find((t) => t.type === "page" && t.webSocketDebuggerUrl) ||
        targets.find((t) => t.webSocketDebuggerUrl);

      if (page) return page;
    } catch {}

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error("Chromium is not ready yet.");
}

async function cdp(method, params = {}) {
  const page = await waitForCdp();

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    const id = Math.floor(Math.random() * 1000000000);

    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error("CDP timeout."));
    }, 10000);

    ws.on("open", () => {
      ws.send(JSON.stringify({ id, method, params }));
    });

    ws.on("message", (data) => {
      try {
        const msg = JSON.parse(String(data));

        if (msg.id === id) {
          clearTimeout(timer);
          ws.close();

          if (msg.error) reject(new Error(msg.error.message || "CDP error."));
          else resolve(msg.result || {});
        }
      } catch {}
    });

    ws.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function configureGermanyAndTouch() {
  try {
    await cdp("Emulation.setTouchEmulationEnabled", {
      enabled: true,
      maxTouchPoints: 5
    });
  } catch {}

  try {
    await cdp("Emulation.setTimezoneOverride", {
      timezoneId: GERMANY.timezone
    });
  } catch {}

  try {
    await cdp("Emulation.setLocaleOverride", {
      locale: GERMANY.locale
    });
  } catch {}

  try {
    await cdp("Emulation.setGeolocationOverride", {
      latitude: GERMANY.latitude,
      longitude: GERMANY.longitude,
      accuracy: GERMANY.accuracy
    });
  } catch {}

  try {
    await cdp("Browser.grantPermissions", {
      permissions: ["geolocation"]
    });
  } catch {}
}

function startBrowser() {
  const chromeBin = findChromium();
  if (!chromeBin) {
    console.error("Chromium not found.");
    process.exit(1);
  }

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "codespace-real-novnc-"));

  const profileDir = path.join(tempRoot, "profile");
  const cacheDir = path.join(tempRoot, "cache");
  const mediaCacheDir = path.join(tempRoot, "media-cache");
  const homeDir = path.join(tempRoot, "home");
  const runtimeDir = path.join(tempRoot, "runtime");

  fs.mkdirSync(profileDir, { recursive: true });
  fs.mkdirSync(cacheDir, { recursive: true });
  fs.mkdirSync(mediaCacheDir, { recursive: true });
  fs.mkdirSync(homeDir, { recursive: true });
  fs.mkdirSync(runtimeDir, { recursive: true });
  fs.chmodSync(runtimeDir, 0o700);

  const env = {
    DISPLAY: DISPLAY_NUM,
    HOME: homeDir,
    TZ: GERMANY.timezone,
    LANG: "de_DE.UTF-8",
    LANGUAGE: "de_DE:de",
    XDG_CACHE_HOME: path.join(tempRoot, "xdg-cache"),
    XDG_CONFIG_HOME: path.join(tempRoot, "xdg-config"),
    XDG_RUNTIME_DIR: runtimeDir
  };

  spawnChild("Xvfb", [
    DISPLAY_NUM,
    "-screen",
    "0",
    "1500x950x24",
    "-ac",
    "+extension",
    "RANDR"
  ], env);

  setTimeout(() => {
    spawnChild("fluxbox", [], env);
  }, 500);

  setTimeout(() => {
    spawnChild("x11vnc", [
      "-display",
      DISPLAY_NUM,
      "-localhost",
      "-forever",
      "-shared",
      "-nopw",
      "-rfbport",
      String(VNC_PORT),
      "-quiet"
    ], env);
  }, 1000);

  setTimeout(() => {
    spawnChild(chromeBin, [
      `--user-data-dir=${profileDir}`,
      `--disk-cache-dir=${cacheDir}`,
      `--media-cache-dir=${mediaCacheDir}`,
      `--remote-debugging-port=${CDP_PORT}`,
      "--remote-debugging-address=127.0.0.1",
      "--lang=de-DE",
      `--accept-lang=${GERMANY.acceptLanguage}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-sync",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-dev-shm-usage",
      "--password-store=basic",
      "--use-mock-keychain",
      "--autoplay-policy=no-user-gesture-required",
      "--touch-events=enabled",
      "--enable-pinch",
      "--overscroll-history-navigation=0",
      "--force-dark-mode",
      "--enable-features=WebUIDarkMode",
      "--window-size=1500,950",
      "--start-maximized",
      "--no-sandbox",
      `http://127.0.0.1:${PORT}/real-home.html`
    ], env);
  }, 1500);

  setTimeout(() => {
    configureGermanyAndTouch().catch(() => {});
  }, 3500);

  console.log("Temporary Chromium profile/cookies:");
  console.log(tempRoot);
  console.log("Deleted when app stops/restarts.");
}

server.on("upgrade", (req, socket, head) => {
  if (!req.url.startsWith("/websockify")) {
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
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
  });
});

app.post("/api/navigate", async (req, res) => {
  try {
    let value = clean(req.body?.url || "");

    if (!value) throw new Error("Empty URL.");

    if (!(value.startsWith("http://") || value.startsWith("https://"))) {
      if (value.includes(".") && !value.includes(" ")) {
        value = `https://${value}`;
      } else {
        value = `https://duckduckgo.com/?kl=de-de&kad=de_DE&q=${encodeURIComponent(value)}`;
      }
    }

    await configureGermanyAndTouch();
    await cdp("Page.navigate", { url: value });

    res.json({ ok: true, url: value });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.post("/api/text", async (req, res) => {
  try {
    const text = String(req.body?.text || "");
    if (text) await cdp("Input.insertText", { text });
    res.json({ ok: true });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.post("/api/key", async (req, res) => {
  try {
    const key = String(req.body?.key || "");
    const keyMap = {
      Enter: 13,
      Backspace: 8,
      Tab: 9,
      Escape: 27,
      ArrowLeft: 37,
      ArrowUp: 38,
      ArrowRight: 39,
      ArrowDown: 40,
      Delete: 46
    };

    const code = keyMap[key] || 0;

    await cdp("Input.dispatchKeyEvent", {
      type: "rawKeyDown",
      key,
      code: key,
      windowsVirtualKeyCode: code,
      nativeVirtualKeyCode: code
    });

    await cdp("Input.dispatchKeyEvent", {
      type: "keyUp",
      key,
      code: key,
      windowsVirtualKeyCode: code,
      nativeVirtualKeyCode: code
    });

    res.json({ ok: true });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.post("/api/youtube", async (req, res) => {
  try {
    const action = String(req.body?.action || "");
    const seconds = Number(req.body?.seconds || 0);

    const expression = `
(() => {
  const action = ${JSON.stringify(action)};
  const seconds = ${JSON.stringify(Number.isFinite(seconds) ? seconds : 0)};
  const video = document.querySelector("video");
  if (!video) return { ok: false, reason: "No video found" };

  if (action === "seek") {
    const duration = Number.isFinite(video.duration) ? video.duration : 999999;
    video.currentTime = Math.max(0, Math.min(duration, video.currentTime + seconds));
    return { ok: true };
  }

  if (action === "togglePlay") {
    if (video.paused) video.play();
    else video.pause();
    return { ok: true };
  }

  if (action === "speedStart") {
    if (!window.__oldRate) window.__oldRate = video.playbackRate || 1;
    video.playbackRate = 2;
    return { ok: true };
  }

  if (action === "speedEnd") {
    video.playbackRate = window.__oldRate || 1;
    window.__oldRate = null;
    return { ok: true };
  }

  return { ok: false };
})()
`;

    const result = await cdp("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true
    });

    res.json({ ok: true, result });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.get("/api/germany-test", async (req, res) => {
  try {
    await configureGermanyAndTouch();

    const result = await cdp("Runtime.evaluate", {
      expression: "({ language: navigator.language, languages: navigator.languages, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, href: location.href })",
      returnByValue: true
    });

    res.json({
      ok: true,
      note: "Browser reports German language/timezone/geolocation. Real IP is still GitHub Codespaces.",
      result
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

function cleanup() {
  for (const child of children) {
    try { child.kill("SIGTERM"); } catch {}
  }

  if (tempRoot) {
    try { fs.rmSync(tempRoot, { recursive: true, force: true }); } catch {}
  }
}

process.on("SIGINT", () => {
  cleanup();
  process.exit(0);
});

process.on("SIGTERM", () => {
  cleanup();
  process.exit(0);
});

server.listen(PORT, "0.0.0.0", () => {
  startBrowser();

  console.log("");
  console.log("====================================================");
  console.log(" Real noVNC Chromium Browser running");
  console.log(` Open Codespaces port: ${PORT}`);
  console.log(" Bad CDP canvas renderer removed.");
  console.log(" Cookies/profile are temporary and deleted on restart.");
  console.log(" Germany browser signals enabled.");
  console.log("====================================================");
  console.log("");
});
EOF

cat > public/index.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Real noVNC Browser</title>
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>
  <div class="app">
    <header class="topbar">
      <div class="brand">
        <div class="brandIcon">◈</div>
        <div>
          <div class="brandTitle">Real Browser</div>
          <div class="brandSub">noVNC + Chromium, no bad screencast canvas</div>
        </div>
      </div>

      <div class="address">
        <input id="addressInput" autocomplete="off" spellcheck="false" placeholder="Search or enter URL..." />
        <button id="goBtn">Go</button>
      </div>

      <button id="keyboardBtn">Keyboard</button>
      <button id="ytBackBtn">−10</button>
      <button id="ytPlayBtn">Play</button>
      <button id="ytForwardBtn">+10</button>
      <button id="reloadBtn">Reload</button>
      <button id="focusBtn">⛶</button>
    </header>

    <main class="viewer">
      <iframe id="realFrame" src="/real.html" allow="clipboard-read; clipboard-write; fullscreen; autoplay"></iframe>
    </main>

    <input id="keyboardBox" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" placeholder="Type here → sends to focused Chromium field" />

    <div id="toast"></div>
  </div>

  <script src="/app.js"></script>
</body>
</html>
EOF

cat > public/real.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>Official noVNC Screen</title>
  <style>
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #05070d;
      overscroll-behavior: none;
    }

    iframe {
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      border: 0;
      background: #05070d;
    }
  </style>
</head>
<body>
  <iframe
    src="/novnc/vnc.html?autoconnect=1&resize=scale&path=websockify&reconnect=1&show_dot=1&logging=warn"
    allow="clipboard-read; clipboard-write; fullscreen; autoplay"
  ></iframe>
</body>
</html>
EOF

cat > public/real-home.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>Real Browser Home</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #070913;
      --panel: rgba(18,23,38,.82);
      --border: rgba(255,255,255,.14);
      --muted: #a2abc7;
      --accent: #7c5cff;
      --accent2: #00d4ff;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at top left, rgba(124,92,255,.34), transparent 34%),
        radial-gradient(circle at bottom right, rgba(0,212,255,.22), transparent 34%),
        var(--bg);
      color: white;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    main {
      width: min(980px, calc(100vw - 48px));
      padding: 42px;
      border: 1px solid var(--border);
      border-radius: 34px;
      background: var(--panel);
      box-shadow: 0 32px 120px rgba(0,0,0,.48);
    }

    .badge {
      display: inline-flex;
      padding: 9px 14px;
      border-radius: 999px;
      border: 1px solid var(--border);
      color: var(--muted);
      margin-bottom: 22px;
    }

    h1 {
      max-width: 820px;
      margin: 0;
      font-size: clamp(44px, 7vw, 86px);
      letter-spacing: -.08em;
      line-height: .92;
      background: linear-gradient(135deg, white, #b4b9ff, var(--accent2));
      -webkit-background-clip: text;
      color: transparent;
    }

    p {
      max-width: 760px;
      margin: 24px 0 0;
      color: var(--muted);
      font-size: 18px;
      line-height: 1.65;
    }

    .links {
      margin-top: 30px;
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
    }

    a {
      text-decoration: none;
      color: white;
      font-weight: 800;
      padding: 13px 17px;
      border-radius: 16px;
      border: 1px solid var(--border);
      background: rgba(255,255,255,.08);
    }

    .primary {
      border: 0;
      background: linear-gradient(135deg, var(--accent), var(--accent2));
    }
  </style>
</head>
<body>
  <main>
    <div class="badge">Official noVNC + real Chromium</div>
    <h1>No more bad screenshot canvas.</h1>
    <p>
      This is a real Chromium window rendered through noVNC. Cookies are temporary.
      German language, timezone, and geolocation signals are enabled.
    </p>

    <div class="links">
      <a class="primary" href="https://youtube.com">YouTube</a>
      <a href="https://duckduckgo.com/?kl=de-de">DuckDuckGo Germany</a>
      <a href="https://google.de">Google Germany</a>
      <a href="https://github.com">GitHub</a>
    </div>
  </main>
</body>
</html>
EOF

cat > public/styles.css <<'EOF'
:root {
  --bg: #070913;
  --panel: rgba(18, 23, 38, 0.82);
  --border: rgba(255,255,255,.13);
  --text: #f7f8ff;
  --muted: #9ea8c5;
  --accent: #7c5cff;
  --accent2: #00d4ff;
}

* { box-sizing: border-box; }

html, body {
  margin: 0;
  height: 100%;
  overflow: hidden;
  background:
    radial-gradient(circle at top left, rgba(124,92,255,.28), transparent 32%),
    radial-gradient(circle at bottom right, rgba(0,212,255,.18), transparent 32%),
    var(--bg);
  color: var(--text);
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}

.app {
  width: 100vw;
  height: 100vh;
  padding: 12px;
  display: grid;
  grid-template-rows: auto 1fr;
  gap: 10px;
}

.topbar {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 68px;
  padding: 10px;
  border: 1px solid var(--border);
  border-radius: 26px;
  background: var(--panel);
  backdrop-filter: blur(22px);
  box-shadow: 0 24px 80px rgba(0,0,0,.38);
}

.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 245px;
}

.brandIcon {
  width: 44px;
  height: 44px;
  display: grid;
  place-items: center;
  border-radius: 17px;
  background: linear-gradient(135deg, var(--accent), var(--accent2));
  font-size: 22px;
}

.brandTitle {
  font-weight: 950;
  letter-spacing: -.03em;
}

.brandSub {
  font-size: 12px;
  color: var(--muted);
}

.address {
  flex: 1;
  display: flex;
  height: 46px;
  border: 1px solid var(--border);
  border-radius: 17px;
  overflow: hidden;
  background: rgba(0,0,0,.25);
}

.address input {
  flex: 1;
  min-width: 0;
  border: 0;
  outline: 0;
  background: transparent;
  color: white;
  padding: 0 15px;
  font: inherit;
}

button {
  border: 1px solid var(--border);
  color: white;
  background: rgba(255,255,255,.08);
  height: 44px;
  padding: 0 13px;
  border-radius: 15px;
  font: 850 13px system-ui, sans-serif;
}

.address button {
  border: 0;
  border-radius: 0;
  padding: 0 18px;
  background: linear-gradient(135deg, var(--accent), var(--accent2));
}

.viewer {
  min-height: 0;
  border: 1px solid var(--border);
  border-radius: 28px;
  overflow: hidden;
  background: #05070d;
  box-shadow: 0 24px 80px rgba(0,0,0,.38);
}

.viewer iframe {
  width: 100%;
  height: 100%;
  border: 0;
  background: #05070d;
}

#keyboardBox {
  position: fixed;
  left: 18px;
  right: 18px;
  bottom: 18px;
  z-index: 50;
  height: 56px;
  display: none;
  border-radius: 18px;
  border: 1px solid var(--border);
  background: rgba(12,16,30,.96);
  color: white;
  padding: 0 16px;
  outline: none;
  font: 18px system-ui, sans-serif;
}

#keyboardBox.visible {
  display: block;
}

#toast {
  position: fixed;
  left: 50%;
  bottom: 88px;
  transform: translateX(-50%);
  display: none;
  padding: 11px 14px;
  border-radius: 999px;
  background: rgba(12,16,30,.94);
  border: 1px solid var(--border);
  color: white;
  z-index: 60;
}

#toast.visible {
  display: block;
}

body.focus .app {
  padding: 0;
  grid-template-rows: 1fr;
}

body.focus .topbar {
  display: none;
}

body.focus .viewer {
  border-radius: 0;
  border: 0;
}

@media (max-width: 950px) {
  .topbar {
    flex-wrap: wrap;
  }

  .brand {
    min-width: 0;
    flex: 1;
  }

  .address {
    order: 10;
    flex-basis: 100%;
  }

  .brandSub {
    display: none;
  }
}
EOF

cat > public/app.js <<'EOF'
const addressInput = document.getElementById("addressInput");
const keyboardBox = document.getElementById("keyboardBox");
const toastEl = document.getElementById("toast");

function toast(text) {
  toastEl.textContent = text;
  toastEl.classList.add("visible");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => toastEl.classList.remove("visible"), 2200);
}

async function postJson(url, body) {
  const r = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store"
    },
    body: JSON.stringify(body)
  });

  const data = await r.json().catch(() => ({}));

  if (!data.ok) {
    throw new Error(data.error || "Request failed.");
  }

  return data;
}

async function navigate() {
  const value = addressInput.value.trim();
  if (!value) return;

  try {
    toast("Opening...");
    const data = await postJson("/api/navigate", { url: value });
    addressInput.value = data.url || value;
    toast("Opened");
  } catch (error) {
    toast(error.message);
  }
}

document.getElementById("goBtn").onclick = navigate;

addressInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") navigate();
});

document.getElementById("reloadBtn").onclick = async () => {
  try {
    await postJson("/api/key", { key: "F5" });
  } catch {
    location.reload();
  }
};

document.getElementById("focusBtn").onclick = () => {
  document.body.classList.toggle("focus");
};

document.getElementById("keyboardBtn").onclick = () => {
  keyboardBox.classList.toggle("visible");

  if (keyboardBox.classList.contains("visible")) {
    keyboardBox.value = "";
    keyboardBox.focus();
    toast("Keyboard open. Tap a remote field first, then type here.");
  } else {
    keyboardBox.blur();
  }
};

keyboardBox.addEventListener("input", async (event) => {
  const value = keyboardBox.value;

  if (event.inputType === "deleteContentBackward") {
    await postJson("/api/key", { key: "Backspace" }).catch(() => {});
    keyboardBox.value = "";
    return;
  }

  if (!value) return;

  await postJson("/api/text", { text: value.replace(/\n/g, "") }).catch(() => {});
  keyboardBox.value = "";
});

keyboardBox.addEventListener("keydown", async (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    await postJson("/api/key", { key: "Enter" }).catch(() => {});
  }

  if (event.key === "Backspace") {
    event.preventDefault();
    await postJson("/api/key", { key: "Backspace" }).catch(() => {});
    keyboardBox.value = "";
  }

  if (event.key === "Tab") {
    event.preventDefault();
    await postJson("/api/key", { key: "Tab" }).catch(() => {});
  }
});

document.getElementById("ytBackBtn").onclick = () => {
  postJson("/api/youtube", { action: "seek", seconds: -10 }).then(() => toast("-10 seconds")).catch(() => toast("No YouTube video found"));
};

document.getElementById("ytPlayBtn").onclick = () => {
  postJson("/api/youtube", { action: "togglePlay" }).then(() => toast("Play/Pause")).catch(() => toast("No YouTube video found"));
};

document.getElementById("ytForwardBtn").onclick = () => {
  postJson("/api/youtube", { action: "seek", seconds: 10 }).then(() => toast("+10 seconds")).catch(() => toast("No YouTube video found"));
};
EOF

cat > .devcontainer/devcontainer.json <<'EOF'
{
  "name": "Real noVNC Browser",
  "image": "mcr.microsoft.com/devcontainers/javascript-node:1-22-bookworm",
  "postCreateCommand": "npm install --no-package-lock",
  "forwardPorts": [7860],
  "portsAttributes": {
    "7860": {
      "label": "Real noVNC Browser",
      "onAutoForward": "openBrowser"
    }
  },
  "otherPortsAttributes": {
    "onAutoForward": "silent"
  }
}
EOF

cat > .gitignore <<'EOF'
node_modules/
package-lock.json
npm-debug.log*
.DS_Store
.env
.cache/
EOF

npm install --no-package-lock

echo ""
echo "Starting real noVNC browser..."
echo "Open port 7860."
echo ""

PORT=7860 npm start
