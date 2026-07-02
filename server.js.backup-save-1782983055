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
