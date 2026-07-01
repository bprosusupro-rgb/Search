#!/usr/bin/env bash
set -e

echo "Installing CDP touch + keyboard browser..."

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
  ca-certificates \
  fonts-liberation \
  fonts-noto-color-emoji \
  xdg-utils

mkdir -p public .devcontainer

cat > package.json <<'EOF'
{
  "name": "codespace-cdp-touch-browser",
  "version": "4.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "cheerio": "^1.0.0",
    "express": "^4.19.2",
    "ws": "^8.18.0"
  }
}
EOF

cat > server.js <<'EOF'
import express from "express";
import * as cheerio from "cheerio";
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
const CDP_PORT = 45992;
const DISPLAY_NUM = ":99";

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

let tempRoot = null;
let chromeStarted = false;
let chromeProcess = null;
let xvfbProcess = null;
let fluxboxProcess = null;

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

function cleanText(value = "") {
  return String(value).replace(/\s+/g, " ").trim();
}

function normalizeUrl(raw) {
  const value = cleanText(raw);
  if (!value) throw new Error("Empty URL.");
  if (value.startsWith("http://") || value.startsWith("https://")) return value;
  return `https://${value}`;
}

function isBlockedHost(hostname) {
  const host = String(hostname || "").toLowerCase();
  if (!host) return true;

  if (
    host === "localhost" ||
    host === "0.0.0.0" ||
    host === "127.0.0.1" ||
    host === "::1" ||
    host.endsWith(".local")
  ) return true;

  const ipType = net.isIP(host);

  if (ipType === 4) {
    const parts = host.split(".").map(Number);
    if (parts[0] === 10) return true;
    if (parts[0] === 127) return true;
    if (parts[0] === 169 && parts[1] === 254) return true;
    if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true;
    if (parts[0] === 192 && parts[1] === 168) return true;
  }

  return false;
}

function safePublicUrl(raw) {
  const url = new URL(normalizeUrl(raw));

  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("Only http and https URLs are allowed.");
  }

  if (isBlockedHost(url.hostname)) {
    throw new Error("Local/private network URLs are blocked.");
  }

  return url;
}

function commandExists(name) {
  const paths = (process.env.PATH || "").split(":");
  return paths.some((p) => fs.existsSync(path.join(p, name)));
}

function findChromium() {
  for (const name of ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]) {
    if (commandExists(name)) return name;
  }
  return null;
}

function spawnQuiet(cmd, args, env = {}) {
  return spawn(cmd, args, {
    stdio: "ignore",
    env: {
      ...process.env,
      ...env
    }
  });
}

function startChrome() {
  if (chromeStarted) return;
  chromeStarted = true;

  const chromeBin = findChromium();
  if (!chromeBin) {
    console.error("Chromium not found.");
    return;
  }

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "codespace-cdp-browser-"));

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
    XDG_CACHE_HOME: path.join(tempRoot, "xdg-cache"),
    XDG_CONFIG_HOME: path.join(tempRoot, "xdg-config"),
    XDG_RUNTIME_DIR: runtimeDir
  };

  xvfbProcess = spawnQuiet("Xvfb", [
    DISPLAY_NUM,
    "-screen",
    "0",
    "1500x950x24",
    "-ac",
    "+extension",
    "RANDR"
  ], env);

  setTimeout(() => {
    fluxboxProcess = spawnQuiet("fluxbox", [], env);
  }, 500);

  setTimeout(() => {
    chromeProcess = spawnQuiet(chromeBin, [
      `--user-data-dir=${profileDir}`,
      `--disk-cache-dir=${cacheDir}`,
      `--media-cache-dir=${mediaCacheDir}`,
      `--remote-debugging-port=${CDP_PORT}`,
      "--remote-debugging-address=127.0.0.1",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-sync",
      "--disable-background-networking",
      "--disable-component-update",
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
  }, 1200);

  console.log("Temporary Chromium profile/cookies:");
  console.log(tempRoot);
}

async function waitForChrome(retries = 40) {
  for (let i = 0; i < retries; i++) {
    try {
      const response = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
      const targets = await response.json();

      const page =
        targets.find((t) => t.type === "page" && t.webSocketDebuggerUrl) ||
        targets.find((t) => t.webSocketDebuggerUrl);

      if (page) return page;
    } catch {}

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error("Chromium CDP is not ready.");
}

async function oneShotCdp(method, params = {}) {
  const page = await waitForChrome();

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    const id = Math.floor(Math.random() * 1_000_000_000);

    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error("CDP timeout."));
    }, 8000);

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

async function configureTouch() {
  try {
    await oneShotCdp("Emulation.setTouchEmulationEnabled", {
      enabled: true,
      maxTouchPoints: 5
    });
  } catch {}
}

function createCdpRenderer(client) {
  let chrome = null;
  let nextId = 1;
  const pending = new Map();

  const sendClient = (obj) => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify(obj));
    }
  };

  const sendChrome = (method, params = {}) => {
    if (!chrome || chrome.readyState !== WebSocket.OPEN) return Promise.reject(new Error("Chrome WebSocket not open."));

    const id = nextId++;
    chrome.send(JSON.stringify({ id, method, params }));

    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });

      setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error(`CDP command timed out: ${method}`));
        }
      }, 10000);
    });
  };

  const sendInputTouch = async (kind, points = []) => {
    await sendChrome("Input.dispatchTouchEvent", {
      type: kind,
      touchPoints: points.map((p) => ({
        x: Math.round(p.x),
        y: Math.round(p.y),
        id: p.id || 1,
        radiusX: 5,
        radiusY: 5,
        force: 1
      }))
    });
  };

  const sendMouse = async (type, x, y, extra = {}) => {
    await sendChrome("Input.dispatchMouseEvent", {
      type,
      x: Math.round(x),
      y: Math.round(y),
      ...extra
    });
  };

  const keyMap = {
    Enter: 13,
    Backspace: 8,
    Tab: 9,
    Escape: 27,
    ArrowLeft: 37,
    ArrowUp: 38,
    ArrowRight: 39,
    ArrowDown: 40,
    Delete: 46,
    Home: 36,
    End: 35
  };

  const pressKey = async (key) => {
    const code = keyMap[key] || 0;

    await sendChrome("Input.dispatchKeyEvent", {
      type: "rawKeyDown",
      key,
      code: key,
      windowsVirtualKeyCode: code,
      nativeVirtualKeyCode: code
    });

    await sendChrome("Input.dispatchKeyEvent", {
      type: "keyUp",
      key,
      code: key,
      windowsVirtualKeyCode: code,
      nativeVirtualKeyCode: code
    });
  };

  waitForChrome().then((page) => {
    chrome = new WebSocket(page.webSocketDebuggerUrl);

    chrome.on("open", async () => {
      sendClient({ type: "status", text: "Connected to Chromium CDP renderer." });

      await sendChrome("Page.enable");
      await sendChrome("Runtime.enable");
      await sendChrome("Emulation.setTouchEmulationEnabled", {
        enabled: true,
        maxTouchPoints: 5
      });

      await sendChrome("Page.startScreencast", {
        format: "jpeg",
        quality: 70,
        maxWidth: 1500,
        maxHeight: 950,
        everyNthFrame: 1
      });

      sendClient({ type: "ready" });
    });

    chrome.on("message", async (data) => {
      let msg;

      try {
        msg = JSON.parse(String(data));
      } catch {
        return;
      }

      if (msg.id && pending.has(msg.id)) {
        const item = pending.get(msg.id);
        pending.delete(msg.id);

        if (msg.error) item.reject(new Error(msg.error.message || "CDP error."));
        else item.resolve(msg.result || {});
      }

      if (msg.method === "Page.screencastFrame") {
        const { data: imageData, metadata, sessionId } = msg.params;

        sendClient({
          type: "frame",
          image: imageData,
          metadata
        });

        try {
          await sendChrome("Page.screencastFrameAck", { sessionId });
        } catch {}
      }
    });

    chrome.on("close", () => {
      sendClient({ type: "status", text: "Chromium connection closed." });
    });

    chrome.on("error", (error) => {
      sendClient({ type: "error", error: error.message || String(error) });
    });
  }).catch((error) => {
    sendClient({ type: "error", error: error.message || String(error) });
  });

  client.on("message", async (data) => {
    try {
      const msg = JSON.parse(String(data));

      if (msg.type === "navigate") {
        const url = safePublicUrl(msg.url);
        await sendChrome("Page.navigate", { url: url.href });
        return;
      }

      if (msg.type === "reload") {
        await sendChrome("Page.reload", { ignoreCache: true });
        return;
      }

      if (msg.type === "back") {
        await sendChrome("Runtime.evaluate", { expression: "history.back()" });
        return;
      }

      if (msg.type === "forward") {
        await sendChrome("Runtime.evaluate", { expression: "history.forward()" });
        return;
      }

      if (msg.type === "touchStart") {
        await sendInputTouch("touchStart", msg.points || []);
        return;
      }

      if (msg.type === "touchMove") {
        await sendInputTouch("touchMove", msg.points || []);
        return;
      }

      if (msg.type === "touchEnd") {
        await sendInputTouch("touchEnd", []);
        return;
      }

      if (msg.type === "tap") {
        const x = Number(msg.x || 0);
        const y = Number(msg.y || 0);

        await sendInputTouch("touchStart", [{ x, y, id: 1 }]);
        await sendInputTouch("touchEnd", []);
        await sendMouse("mousePressed", x, y, { button: "left", buttons: 1, clickCount: 1 });
        await sendMouse("mouseReleased", x, y, { button: "left", buttons: 0, clickCount: 1 });
        return;
      }

      if (msg.type === "wheel") {
        await sendMouse("mouseWheel", Number(msg.x || 0), Number(msg.y || 0), {
          deltaX: Number(msg.deltaX || 0),
          deltaY: Number(msg.deltaY || 0),
          button: "none",
          buttons: 0
        });
        return;
      }

      if (msg.type === "mouseMove") {
        await sendMouse("mouseMoved", Number(msg.x || 0), Number(msg.y || 0), {
          button: "none",
          buttons: 0
        });
        return;
      }

      if (msg.type === "insertText") {
        await sendChrome("Input.insertText", { text: String(msg.text || "") });
        return;
      }

      if (msg.type === "key") {
        await pressKey(String(msg.key || ""));
        return;
      }
    } catch (error) {
      sendClient({ type: "error", error: error.message || String(error) });
    }
  });

  client.on("close", () => {
    try {
      chrome?.close();
    } catch {}
  });
}

server.on("upgrade", (req, socket, head) => {
  if (!req.url.startsWith("/cdp-renderer")) {
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (client) => {
    createCdpRenderer(client);
  });
});

function unwrapDuckDuckGoUrl(href) {
  try {
    if (!href) return "";
    let urlText = href;
    if (urlText.startsWith("//")) urlText = `https:${urlText}`;
    if (urlText.startsWith("/")) urlText = `https://duckduckgo.com${urlText}`;

    const url = new URL(urlText);
    const uddg = url.searchParams.get("uddg");
    if (uddg) return decodeURIComponent(uddg);
    return url.href;
  } catch {
    return href || "";
  }
}

async function fetchText(url, options = {}) {
  const response = await fetch(url, {
    redirect: "follow",
    headers: {
      "User-Agent": "Mozilla/5.0 CodespaceBrowser/4.0 Chrome/124 Safari/537.36",
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5",
      ...options.headers
    },
    signal: AbortSignal.timeout(options.timeoutMs || 15000)
  });

  const contentType = response.headers.get("content-type") || "";
  const text = await response.text();

  return {
    ok: response.ok,
    status: response.status,
    statusText: response.statusText,
    contentType,
    text,
    finalUrl: response.url
  };
}

app.post("/api/real/navigate", async (req, res) => {
  try {
    const url = safePublicUrl(req.body?.url || "");
    await configureTouch();
    await oneShotCdp("Page.navigate", { url: url.href });
    res.json({ ok: true, url: url.href });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.get("/api/real/status", (req, res) => {
  res.json({
    ok: true,
    chromeStarted,
    temporaryProfile: Boolean(tempRoot)
  });
});

app.post("/api/search", async (req, res) => {
  try {
    const q = cleanText(req.body?.q || "");
    if (!q) return res.status(400).json({ ok: false, error: "Search is empty." });

    const searchUrl = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(q)}`;
    const page = await fetchText(searchUrl);

    const $ = cheerio.load(page.text);
    const results = [];
    const seen = new Set();

    $(".result").each((_, el) => {
      const titleEl = $(el).find(".result__a").first();
      const snippetEl = $(el).find(".result__snippet").first();
      const urlEl = $(el).find(".result__url").first();

      const title = cleanText(titleEl.text());
      const href = unwrapDuckDuckGoUrl(titleEl.attr("href") || "");
      const body = cleanText(snippetEl.text());
      const displayUrl = cleanText(urlEl.text()) || href;

      if (!title || !href || seen.has(href)) return;
      seen.add(href);

      results.push({ title, url: href, displayUrl, body });
    });

    res.json({ ok: true, q, results: results.slice(0, 18) });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.post("/api/reader", async (req, res) => {
  try {
    const url = safePublicUrl(req.body?.url || "");
    const page = await fetchText(url.href);

    const $ = cheerio.load(page.text);
    $("script, style, noscript, svg, canvas, iframe, form, nav, footer, aside").remove();

    const title =
      cleanText($("title").first().text()) ||
      cleanText($("h1").first().text()) ||
      url.hostname;

    const parts = [];

    $("main article h1, main article h2, main article h3, main article p, main article li, article h1, article h2, article h3, article p, article li, h1, h2, h3, p, li").each((_, el) => {
      const text = cleanText($(el).text());
      if (text.length < 35) return;
      if (parts.includes(text)) return;
      parts.push(text);
    });

    res.json({
      ok: true,
      url: page.finalUrl || url.href,
      title,
      parts: parts.slice(0, 120)
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.get("/api/proxy", async (req, res) => {
  try {
    const url = safePublicUrl(req.query.url || "");
    const page = await fetchText(url.href);

    const $ = cheerio.load(page.text);
    $("meta[http-equiv='Content-Security-Policy']").remove();

    if ($("head").length === 0) $("html").prepend("<head></head>");
    $("head").prepend(`<base href="${page.finalUrl || url.href}">`);

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.send($.html());
  } catch (error) {
    res.status(500).send(error.message || String(error));
  }
});

function cleanup() {
  for (const p of [chromeProcess, fluxboxProcess, xvfbProcess]) {
    try { p?.kill("SIGTERM"); } catch {}
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
  startChrome();

  console.log("");
  console.log("====================================================");
  console.log(" CDP Touch Browser running");
  console.log(` Open Codespaces forwarded port: ${PORT}`);
  console.log(" Touch + keyboard are now CDP-based, not noVNC.");
  console.log(" Cookies/profile are temporary and deleted on restart.");
  console.log("====================================================");
  console.log("");
});
EOF

cat > public/real.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>CDP Touch Renderer</title>
  <style>
    :root { color-scheme: dark; }

    html,
    body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #05070d;
      touch-action: none;
      overscroll-behavior: none;
      -webkit-user-select: none;
      user-select: none;
    }

    body {
      position: fixed;
      inset: 0;
    }

    #canvas {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      display: block;
      background: #05070d;
      touch-action: none;
    }

    #status {
      position: fixed;
      left: 14px;
      top: 14px;
      z-index: 20;
      padding: 10px 13px;
      border-radius: 999px;
      background: rgba(10, 14, 26, 0.88);
      color: white;
      font: 13px system-ui, sans-serif;
      border: 1px solid rgba(255,255,255,0.15);
      pointer-events: none;
    }

    #toolbar {
      position: fixed;
      right: 12px;
      top: 12px;
      z-index: 30;
      display: flex;
      gap: 8px;
      align-items: center;
      padding: 8px;
      border-radius: 18px;
      background: rgba(10, 14, 26, 0.76);
      border: 1px solid rgba(255,255,255,0.14);
      backdrop-filter: blur(14px);
    }

    button {
      border: 1px solid rgba(255,255,255,0.18);
      color: white;
      background: rgba(255,255,255,0.09);
      border-radius: 13px;
      padding: 9px 11px;
      font: 800 12px system-ui, sans-serif;
    }

    button.active {
      border: 0;
      background: linear-gradient(135deg, #7c5cff, #00d4ff);
    }

    #keyboardBox {
      position: fixed;
      left: 14px;
      right: 14px;
      bottom: 14px;
      z-index: 35;
      height: 54px;
      border-radius: 18px;
      border: 1px solid rgba(255,255,255,0.18);
      background: rgba(10, 14, 26, 0.92);
      color: white;
      padding: 0 16px;
      font: 18px system-ui, sans-serif;
      outline: none;
      display: none;
    }

    #keyboardBox.visible {
      display: block;
    }

    #hint {
      position: fixed;
      left: 14px;
      bottom: 14px;
      z-index: 25;
      max-width: min(620px, calc(100vw - 28px));
      padding: 10px 12px;
      border-radius: 16px;
      background: rgba(10, 14, 26, 0.74);
      color: rgba(255,255,255,0.78);
      font: 12px/1.4 system-ui, sans-serif;
      border: 1px solid rgba(255,255,255,0.12);
      backdrop-filter: blur(14px);
      pointer-events: none;
    }
  </style>
</head>

<body>
  <canvas id="canvas"></canvas>

  <div id="status">Connecting to Chromium...</div>

  <div id="toolbar">
    <button id="touchBtn" class="active">Touch</button>
    <button id="mouseBtn">Mouse</button>
    <button id="keyboardBtn">Keyboard</button>
    <button id="backspaceBtn">⌫</button>
    <button id="enterBtn">Enter</button>
    <button id="reloadBtn">↻</button>
  </div>

  <input id="keyboardBox" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" />

  <div id="hint">
    Tap = real touch/click. Drag = touch drag. Two fingers = scroll. Tap a field, then Keyboard, then type.
  </div>

  <script>
    const canvas = document.getElementById("canvas");
    const ctx = canvas.getContext("2d");
    const statusEl = document.getElementById("status");
    const keyboardBox = document.getElementById("keyboardBox");
    const touchBtn = document.getElementById("touchBtn");
    const mouseBtn = document.getElementById("mouseBtn");

    let ws;
    let mode = "touch";
    let lastFrameMeta = { deviceWidth: 1500, deviceHeight: 950 };
    let activePointers = new Map();
    let lastTwoFinger = null;
    let lastTap = { time: 0, x: 0, y: 0 };
    let keyboardOpen = false;

    function setStatus(text, hide = false) {
      statusEl.style.display = "block";
      statusEl.textContent = text;

      if (hide) {
        clearTimeout(setStatus.timer);
        setStatus.timer = setTimeout(() => {
          statusEl.style.display = "none";
        }, 1400);
      }
    }

    function send(obj) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(obj));
      }
    }

    function connect() {
      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      ws = new WebSocket(`${protocol}//${location.host}/cdp-renderer`);

      ws.onopen = () => setStatus("Connected to CDP renderer.", true);

      ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);

        if (msg.type === "status") {
          setStatus(msg.text, true);
        }

        if (msg.type === "error") {
          setStatus(msg.error || "Renderer error.");
        }

        if (msg.type === "frame") {
          drawFrame(msg.image, msg.metadata || {});
        }
      };

      ws.onclose = () => {
        setStatus("Disconnected. Reconnecting...");
        setTimeout(connect, 1000);
      };
    }

    function drawFrame(base64, meta) {
      lastFrameMeta = {
        deviceWidth: meta.deviceWidth || meta.viewportWidth || lastFrameMeta.deviceWidth || 1500,
        deviceHeight: meta.deviceHeight || meta.viewportHeight || lastFrameMeta.deviceHeight || 950
      };

      const img = new Image();

      img.onload = () => {
        canvas.width = img.width;
        canvas.height = img.height;
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      };

      img.src = `data:image/jpeg;base64,${base64}`;
    }

    function pointFromEvent(event) {
      const rect = canvas.getBoundingClientRect();

      const rx = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
      const ry = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));

      return {
        id: event.pointerId || 1,
        x: Math.round(rx * (lastFrameMeta.deviceWidth || 1500)),
        y: Math.round(ry * (lastFrameMeta.deviceHeight || 950))
      };
    }

    function pointsArray() {
      return Array.from(activePointers.values());
    }

    function averageClient(points) {
      let x = 0;
      let y = 0;

      for (const p of points) {
        x += p.clientX;
        y += p.clientY;
      }

      return {
        x: x / points.length,
        y: y / points.length
      };
    }

    function remoteFromClientPoint(clientX, clientY) {
      const rect = canvas.getBoundingClientRect();

      const rx = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
      const ry = Math.max(0, Math.min(1, (clientY - rect.top) / rect.height));

      return {
        x: Math.round(rx * (lastFrameMeta.deviceWidth || 1500)),
        y: Math.round(ry * (lastFrameMeta.deviceHeight || 950))
      };
    }

    canvas.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      canvas.setPointerCapture(event.pointerId);

      const p = pointFromEvent(event);

      activePointers.set(event.pointerId, {
        ...p,
        clientX: event.clientX,
        clientY: event.clientY
      });

      if (activePointers.size >= 2) {
        lastTwoFinger = averageClient(Array.from(activePointers.values()));
        return;
      }

      if (mode === "mouse" || event.pointerType === "mouse") {
        send({
          type: "tap",
          x: p.x,
          y: p.y
        });
        return;
      }

      send({
        type: "touchStart",
        points: [p]
      });
    }, { passive: false });

    canvas.addEventListener("pointermove", (event) => {
      event.preventDefault();

      if (!activePointers.has(event.pointerId)) return;

      const p = pointFromEvent(event);

      activePointers.set(event.pointerId, {
        ...p,
        clientX: event.clientX,
        clientY: event.clientY
      });

      const all = Array.from(activePointers.values());

      if (all.length >= 2) {
        const now = averageClient(all);
        const remote = remoteFromClientPoint(now.x, now.y);

        if (lastTwoFinger) {
          send({
            type: "wheel",
            x: remote.x,
            y: remote.y,
            deltaX: -(now.x - lastTwoFinger.x) * 2.8,
            deltaY: -(now.y - lastTwoFinger.y) * 2.8
          });
        }

        lastTwoFinger = now;
        return;
      }

      if (mode === "touch" && event.pointerType !== "mouse") {
        send({
          type: "touchMove",
          points: [p]
        });
      } else {
        send({
          type: "mouseMove",
          x: p.x,
          y: p.y
        });
      }
    }, { passive: false });

    canvas.addEventListener("pointerup", (event) => {
      event.preventDefault();

      const p = pointFromEvent(event);
      activePointers.delete(event.pointerId);

      if (activePointers.size === 0) {
        lastTwoFinger = null;
      }

      const now = performance.now();
      const dx = Math.abs(p.x - lastTap.x);
      const dy = Math.abs(p.y - lastTap.y);
      const wasTap = now - lastTap.time < 450 && dx < 18 && dy < 18;

      lastTap = { time: now, x: p.x, y: p.y };

      if (mode === "touch" && event.pointerType !== "mouse") {
        send({ type: "touchEnd" });

        if (!wasTap) {
          send({
            type: "tap",
            x: p.x,
            y: p.y
          });
        }
      }
    }, { passive: false });

    canvas.addEventListener("pointercancel", (event) => {
      event.preventDefault();
      activePointers.clear();
      lastTwoFinger = null;
      send({ type: "touchEnd" });
    }, { passive: false });

    canvas.addEventListener("wheel", (event) => {
      event.preventDefault();

      const p = remoteFromClientPoint(event.clientX, event.clientY);

      send({
        type: "wheel",
        x: p.x,
        y: p.y,
        deltaX: event.deltaX,
        deltaY: event.deltaY
      });
    }, { passive: false });

    function showKeyboard() {
      keyboardOpen = !keyboardOpen;
      keyboardBox.classList.toggle("visible", keyboardOpen);

      if (keyboardOpen) {
        keyboardBox.value = "";
        keyboardBox.focus();
        setStatus("Keyboard open. Text is inserted into the focused Chromium field.", true);
      } else {
        keyboardBox.blur();
      }
    }

    keyboardBox.addEventListener("input", (event) => {
      const value = keyboardBox.value;

      if (event.inputType === "deleteContentBackward") {
        send({ type: "key", key: "Backspace" });
        keyboardBox.value = "";
        return;
      }

      if (!value) return;

      const normalized = value.replace(/\n/g, "");
      if (normalized) {
        send({
          type: "insertText",
          text: normalized
        });
      }

      keyboardBox.value = "";
    });

    keyboardBox.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        send({ type: "key", key: "Enter" });
        keyboardBox.value = "";
      }

      if (event.key === "Backspace") {
        event.preventDefault();
        send({ type: "key", key: "Backspace" });
        keyboardBox.value = "";
      }

      if (event.key === "Tab") {
        event.preventDefault();
        send({ type: "key", key: "Tab" });
      }

      if (event.key === "Escape") {
        event.preventDefault();
        send({ type: "key", key: "Escape" });
      }
    });

    document.getElementById("keyboardBtn").onclick = showKeyboard;

    document.getElementById("backspaceBtn").onclick = () => {
      send({ type: "key", key: "Backspace" });
    };

    document.getElementById("enterBtn").onclick = () => {
      send({ type: "key", key: "Enter" });
    };

    document.getElementById("reloadBtn").onclick = () => {
      send({ type: "reload" });
    };

    touchBtn.onclick = () => {
      mode = "touch";
      touchBtn.classList.add("active");
      mouseBtn.classList.remove("active");
      setStatus("Touch mode active.", true);
    };

    mouseBtn.onclick = () => {
      mode = "mouse";
      mouseBtn.classList.add("active");
      touchBtn.classList.remove("active");
      setStatus("Mouse mode active.", true);
    };

    document.addEventListener("gesturestart", (e) => e.preventDefault(), { passive: false });
    document.addEventListener("gesturechange", (e) => e.preventDefault(), { passive: false });
    document.addEventListener("gestureend", (e) => e.preventDefault(), { passive: false });
    document.addEventListener("contextmenu", (e) => e.preventDefault());

    connect();
  </script>
</body>
</html>
EOF

cat > public/real-home.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>CDP Browser Home</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #070913;
      --panel: rgba(18, 23, 38, 0.76);
      --border: rgba(255, 255, 255, 0.14);
      --text: #f7f8ff;
      --muted: #a2abc7;
      --accent: #7c5cff;
      --accent2: #00d4ff;
      --good: #4df2a5;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at top left, rgba(124, 92, 255, 0.34), transparent 34%),
        radial-gradient(circle at bottom right, rgba(0, 212, 255, 0.2), transparent 34%),
        var(--bg);
      color: var(--text);
      font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    main {
      width: min(980px, calc(100vw - 48px));
      padding: 42px;
      border: 1px solid var(--border);
      border-radius: 34px;
      background: var(--panel);
      box-shadow: 0 32px 120px rgba(0, 0, 0, 0.48);
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
      letter-spacing: -0.08em;
      line-height: 0.92;
      background: linear-gradient(135deg, white, #b4b9ff, var(--accent2));
      -webkit-background-clip: text;
      background-clip: text;
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
      background: rgba(255, 255, 255, 0.08);
    }

    .primary {
      border: 0;
      background: linear-gradient(135deg, var(--accent), var(--accent2));
    }

    .note {
      margin-top: 24px;
      color: var(--good);
      font-size: 14px;
    }
  </style>
</head>
<body>
  <main>
    <div class="badge">CDP touch + keyboard renderer</div>
    <h1>Real Chromium, real touch events, real keyboard input.</h1>
    <p>
      Tap, drag, scroll, and type through the outer Codespaces UI.
      The Chromium profile and cookies are temporary and deleted when the app restarts.
    </p>

    <div class="links">
      <a class="primary" href="https://youtube.com">YouTube</a>
      <a href="https://duckduckgo.com">DuckDuckGo</a>
      <a href="https://github.com">GitHub</a>
      <a href="https://developer.mozilla.org">MDN</a>
    </div>

    <div class="note">Tip: tap a text field first, then press Keyboard in the top-right.</div>
  </main>
</body>
</html>
EOF

cat > .devcontainer/devcontainer.json <<'EOF'
{
  "name": "CDP Touch Browser",
  "image": "mcr.microsoft.com/devcontainers/javascript-node:1-22-bookworm",
  "postCreateCommand": "npm install --no-package-lock",
  "forwardPorts": [7860],
  "portsAttributes": {
    "7860": {
      "label": "CDP Touch Browser",
      "onAutoForward": "openBrowser"
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
echo "Starting CDP touch browser..."
echo "Open port 7860."
echo ""

PORT=7860 npm start
