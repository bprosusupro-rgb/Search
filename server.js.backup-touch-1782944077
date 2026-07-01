import express from "express";
import * as cheerio from "cheerio";
import path from "node:path";
import net from "node:net";
import os from "node:os";
import fs from "node:fs";
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

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

app.disable("x-powered-by");
app.set("etag", false);
app.use(express.json({ limit: "512kb" }));

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

let tempRoot = null;
let chromeStarted = false;
const children = [];

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

  if (ipType === 6) {
    if (host.includes("::1")) return true;
    if (host.startsWith("fc") || host.startsWith("fd") || host.startsWith("fe80")) return true;
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
      "User-Agent": "Mozilla/5.0 CodespaceBrowser/3.0 Chrome/124 Safari/537.36",
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

function spawnQuiet(cmd, args, envExtra = {}) {
  const child = spawn(cmd, args, {
    stdio: "ignore",
    env: {
      ...process.env,
      ...envExtra
    }
  });

  children.push(child);
  return child;
}

function startRealBrowser() {
  if (chromeStarted) return;
  chromeStarted = true;

  const chromeBin = findChromium();

  if (!chromeBin) {
    console.error("Chromium not found.");
    return;
  }

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "codespace-real-browser-"));

  const profileDir = path.join(tempRoot, "chromium-profile");
  const cacheDir = path.join(tempRoot, "chromium-cache");
  const mediaCacheDir = path.join(tempRoot, "chromium-media-cache");
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

  spawnQuiet("Xvfb", [
    DISPLAY_NUM,
    "-screen",
    "0",
    "1600x1000x24",
    "-ac",
    "+extension",
    "RANDR"
  ], env);

  setTimeout(() => {
    spawnQuiet("fluxbox", [], env);
  }, 600);

  setTimeout(() => {
    spawnQuiet("x11vnc", [
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
  }, 1200);

  setTimeout(() => {
    const homeUrl = `http://127.0.0.1:${PORT}/real-home.html`;

    spawnQuiet(chromeBin, [
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
      "--force-dark-mode",
      "--enable-features=WebUIDarkMode",
      "--autoplay-policy=no-user-gesture-required",
      "--start-maximized",
      "--window-size=1500,950",
      "--no-sandbox",
      homeUrl
    ], env);
  }, 1900);

  console.log("Temporary Chromium cookie/profile folder:");
  console.log(tempRoot);
  console.log("This folder is deleted when the app stops and recreated on next start.");
}

async function cdpNavigate(targetUrl) {
  const url = normalizeUrl(targetUrl);

  const targetsResponse = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
  const targets = await targetsResponse.json();

  const page =
    targets.find((target) => target.type === "page" && target.webSocketDebuggerUrl) ||
    targets.find((target) => target.webSocketDebuggerUrl);

  if (!page) {
    throw new Error("No Chromium page found yet. Wait 2 seconds and try again.");
  }

  await new Promise((resolve, reject) => {
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error("Chromium navigation timed out."));
    }, 8000);

    ws.on("open", () => {
      ws.send(JSON.stringify({
        id: 1,
        method: "Page.navigate",
        params: { url }
      }));
    });

    ws.on("message", (data) => {
      try {
        const msg = JSON.parse(String(data));

        if (msg.id === 1) {
          clearTimeout(timer);
          ws.close();

          if (msg.error) {
            reject(new Error(msg.error.message || "Navigation failed."));
          } else {
            resolve();
          }
        }
      } catch {}
    });

    ws.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function cleanup() {
  console.log("");
  console.log("Stopping and deleting temporary Chromium cookies/profile...");

  for (const child of children) {
    try { child.kill("SIGTERM"); } catch {}
  }

  if (tempRoot) {
    try { fs.rmSync(tempRoot, { recursive: true, force: true }); } catch {}
  }

  console.log("Cleaned.");
}

process.on("SIGINT", () => {
  cleanup();
  process.exit(0);
});

process.on("SIGTERM", () => {
  cleanup();
  process.exit(0);
});

process.on("exit", cleanup);

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

app.post("/api/real/navigate", async (req, res) => {
  try {
    const url = safePublicUrl(req.body?.url || "");
    await cdpNavigate(url.href);
    res.json({ ok: true, url: url.href });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message || String(error) });
  }
});

app.get("/api/real/status", (req, res) => {
  res.json({
    ok: true,
    chromeStarted,
    vncPort: VNC_PORT,
    cdpPort: CDP_PORT,
    temporaryProfile: Boolean(tempRoot)
  });
});

app.post("/api/search", async (req, res) => {
  try {
    const q = cleanText(req.body?.q || "");
    if (!q) return res.status(400).json({ ok: false, error: "Search is empty." });

    const searchUrl = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(q)}`;
    const page = await fetchText(searchUrl);

    if (!page.ok) {
      return res.status(502).json({
        ok: false,
        error: `Search failed: ${page.status} ${page.statusText}`
      });
    }

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

    if (!page.ok) {
      return res.status(502).json({
        ok: false,
        error: `Could not load page: ${page.status} ${page.statusText}`
      });
    }

    if (!page.contentType.includes("text/html") && !page.contentType.includes("text/plain")) {
      return res.status(400).json({
        ok: false,
        error: "Reader mode only supports text/html or text/plain pages."
      });
    }

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

    if (!page.ok) {
      return res.status(502).send(`Could not load page: ${page.status} ${page.statusText}`);
    }

    if (!page.contentType.includes("text/html")) {
      res.setHeader("Content-Type", "text/plain; charset=utf-8");
      return res.send("This preview only supports HTML pages. Use Real or Open instead.");
    }

    const $ = cheerio.load(page.text);
    $("meta[http-equiv='Content-Security-Policy']").remove();

    if ($("head").length === 0) $("html").prepend("<head></head>");
    $("head").prepend(`<base href="${page.finalUrl || url.href}">`);

    $("body").append(`
<script>
(() => {
  document.addEventListener("click", (event) => {
    const link = event.target.closest && event.target.closest("a[href]");
    if (!link) return;
    const href = link.href;
    if (!href) return;
    event.preventDefault();
    window.parent.postMessage({ type: "codespace-browser-navigate", url: href }, "*");
  }, true);
})();
</script>
    `);

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.send($.html());
  } catch (error) {
    res.status(500).send(error.message || String(error));
  }
});


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
  const target = `${proto}://${targetHost}/`;

  res.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store"
  });

  res.end(`<!doctype html>
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
    location.href = ${JSON.stringify(target)};
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
  <a href="${target}">Open correct browser port 7860</a>
</main>
</body>
</html>`);
});

WRONG_PORT_HELPER_5900.listen(5900, "0.0.0.0", () => {
  console.log("Port 5900 helper is active. If opened, it redirects to 7860.");
});

server.listen(PORT, "0.0.0.0", () => {
  startRealBrowser();

  console.log("");
  console.log("====================================================");
  console.log(" Real JS Codespace Browser running");
  console.log(` Open Codespaces forwarded port: ${PORT}`);
  console.log(" Go / Real = real Chromium engine for YouTube + JS sites");
  console.log(" Cookies/cache/profile are temporary and deleted every start/stop.");
  console.log("====================================================");
  console.log("");
});
