#!/usr/bin/env bash
set -e

echo "Stopping old setup and creating new big renderer browser..."

rm -rf public node_modules package-lock.json server.js package.json .devcontainer .gitignore
mkdir -p public .devcontainer

cat > package.json <<'EOF'
{
  "name": "codespace-big-renderer-browser",
  "version": "2.1.0",
  "private": true,
  "type": "module",
  "description": "Renderer-first no-save browser UI for GitHub Codespaces.",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "cheerio": "^1.0.0",
    "express": "^4.19.2"
  }
}
EOF

cat > server.js <<'EOF'
import express from "express";
import * as cheerio from "cheerio";
import path from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PORT = Number(process.env.PORT || 7860);
const app = express();

app.disable("x-powered-by");
app.set("etag", false);
app.use(express.json({ limit: "256kb" }));

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
      "User-Agent": "Mozilla/5.0 CodespaceBrowser/2.1 Chrome/124 Safari/537.36",
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
      return res.send("This preview only supports HTML pages. Use Open instead.");
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

app.listen(PORT, "0.0.0.0", () => {
  console.log("");
  console.log("====================================================");
  console.log(" Big Renderer Codespace Browser running");
  console.log(` Open Codespaces forwarded port: ${PORT}`);
  console.log(" Use the big bottom-right ⛶ button for focus/fullscreen mode.");
  console.log("====================================================");
  console.log("");
});
EOF

cat > public/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <meta http-equiv="Cache-Control" content="no-store" />
  <title>Codespace Browser</title>
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>
  <div class="background-glow glow-one"></div>
  <div class="background-glow glow-two"></div>

  <div class="app">
    <header class="topbar">
      <div class="brand">
        <div class="brand-icon">◈</div>
        <div class="brand-text">
          <div class="brand-title">Codespace Browser</div>
          <div class="brand-subtitle">Big renderer mode</div>
        </div>
      </div>

      <div class="nav-group">
        <button id="backBtn" class="tool-btn" title="Back">←</button>
        <button id="forwardBtn" class="tool-btn" title="Forward">→</button>
        <button id="reloadBtn" class="tool-btn" title="Reload">↻</button>
        <button id="homeBtn" class="tool-btn" title="Home">⌂</button>
      </div>

      <div class="address-shell">
        <span class="address-icon">⌕</span>
        <input id="addressInput" class="address-input" autocomplete="off" spellcheck="false" placeholder="Search with DuckDuckGo or enter a URL..." />
        <button id="goBtn" class="go-btn">Go</button>
      </div>

      <div class="right-actions">
        <button id="readerBtn" class="mode-btn">Reader</button>
        <button id="browserBtn" class="mode-btn">Browser</button>
        <button id="openBtn" class="mode-btn">Open</button>
        <button id="newTabBtn" class="tool-btn" title="New tab">＋</button>
        <button id="clearBtn" class="danger-btn" title="Clear memory">Clear</button>
      </div>
    </header>

    <nav id="tabBar" class="tabbar"></nav>

    <main class="main">
      <section class="viewer">
        <div class="viewer-toolbar">
          <div id="statusText" class="status-pill">Ready.</div>
          <div class="toolbar-hint">Press ⛶ for focus mode.</div>
        </div>

        <div class="viewer-body">
          <div id="loader" class="loader">
            <div class="spinner"></div>
            <span>Loading...</span>
          </div>

          <section id="homeView" class="home-view">
            <div class="hero-card">
              <div class="hero-badge">◈ No sidebar. No tiny renderer.</div>
              <h1>Big browser renderer for Codespaces.</h1>
              <p>
                This version uses the whole screen for the page. Search results, reader mode,
                and website preview all render here instead of being squeezed under a second panel.
              </p>

              <div class="feature-grid">
                <div class="feature-card">
                  <strong>Big renderer</strong>
                  <span>The browser area is now the main layout.</span>
                </div>
                <div class="feature-card">
                  <strong>Focus button</strong>
                  <span>Press the big ⛶ button to make it nearly fullscreen.</span>
                </div>
                <div class="feature-card">
                  <strong>No duplicate search panel</strong>
                  <span>Search results appear inside the main page only.</span>
                </div>
              </div>
            </div>
          </section>

          <section id="searchView" class="search-view"></section>
          <section id="readerView" class="reader-view"></section>

          <section id="browserView" class="browser-view">
            <iframe
              id="browserFrame"
              title="Browser preview"
              sandbox="allow-scripts allow-forms allow-popups allow-modals allow-same-origin"
              referrerpolicy="no-referrer"
            ></iframe>
          </section>
        </div>
      </section>
    </main>
  </div>

  <button id="focusBtn" class="focus-toggle" title="Fullscreen renderer">⛶</button>
  <div id="toast" class="toast"></div>

  <script src="/app.js"></script>
</body>
</html>
EOF

cat > public/styles.css <<'EOF'
:root {
  --bg: #070913;
  --panel: rgba(18, 23, 38, 0.78);
  --panel-strong: rgba(21, 27, 45, 0.96);
  --card: rgba(255, 255, 255, 0.07);
  --card-hover: rgba(255, 255, 255, 0.12);
  --border: rgba(255, 255, 255, 0.12);
  --border-strong: rgba(255, 255, 255, 0.22);
  --text: #f7f8ff;
  --muted: #9ea8c5;
  --muted-2: #6d7590;
  --accent: #7c5cff;
  --accent-2: #00d4ff;
  --danger: #ff4f70;
  --good: #4df2a5;
  --shadow: 0 28px 90px rgba(0, 0, 0, 0.45);
  --radius-xl: 30px;
  --radius-lg: 22px;
  --fast: 170ms ease;
}

* { box-sizing: border-box; }

html, body {
  margin: 0;
  min-height: 100%;
  background: var(--bg);
  color: var(--text);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  overflow: hidden;
}

button, input { font: inherit; }
button { user-select: none; }

.background-glow {
  position: fixed;
  border-radius: 999px;
  filter: blur(60px);
  pointer-events: none;
  opacity: 0.55;
}

.glow-one {
  width: 420px;
  height: 420px;
  left: -120px;
  top: -130px;
  background: rgba(124, 92, 255, 0.75);
}

.glow-two {
  width: 460px;
  height: 460px;
  right: -160px;
  bottom: -170px;
  background: rgba(0, 212, 255, 0.48);
}

.app {
  width: 100vw;
  height: 100vh;
  padding: 14px;
  display: grid;
  grid-template-rows: auto auto 1fr;
  gap: 10px;
}

.topbar {
  min-height: 72px;
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px;
  border: 1px solid var(--border);
  background: var(--panel);
  backdrop-filter: blur(24px);
  border-radius: var(--radius-xl);
  box-shadow: var(--shadow);
  animation: drop-in 420ms ease both;
}

.brand {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 210px;
}

.brand-icon {
  width: 48px;
  height: 48px;
  display: grid;
  place-items: center;
  border-radius: 18px;
  background: linear-gradient(135deg, var(--accent), var(--accent-2));
  box-shadow: 0 16px 38px rgba(124, 92, 255, 0.35);
  font-size: 23px;
}

.brand-title {
  font-weight: 950;
  letter-spacing: -0.03em;
}

.brand-subtitle {
  margin-top: 2px;
  color: var(--muted);
  font-size: 12px;
}

.nav-group, .right-actions {
  display: flex;
  gap: 8px;
  align-items: center;
}

.tool-btn, .mode-btn, .danger-btn, .go-btn, .small-btn {
  border: 1px solid var(--border);
  color: var(--text);
  background: rgba(255, 255, 255, 0.07);
  cursor: pointer;
  transition: transform var(--fast), background var(--fast), border-color var(--fast), opacity var(--fast);
}

.tool-btn {
  width: 44px;
  height: 44px;
  border-radius: 16px;
}

.tool-btn:hover, .mode-btn:hover, .danger-btn:hover, .small-btn:hover {
  transform: translateY(-1px);
  background: rgba(255, 255, 255, 0.13);
  border-color: var(--border-strong);
}

.address-shell {
  flex: 1;
  min-width: 260px;
  height: 50px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding-left: 15px;
  border: 1px solid var(--border);
  background: rgba(0, 0, 0, 0.28);
  border-radius: 19px;
  transition: border-color var(--fast), box-shadow var(--fast), background var(--fast);
}

.address-shell:focus-within {
  border-color: rgba(124, 92, 255, 0.9);
  box-shadow: 0 0 0 5px rgba(124, 92, 255, 0.17);
  background: rgba(0, 0, 0, 0.4);
}

.address-icon { color: var(--muted); }

.address-input {
  flex: 1;
  min-width: 0;
  height: 100%;
  border: 0;
  outline: 0;
  color: var(--text);
  background: transparent;
}

.go-btn {
  height: 40px;
  margin-right: 5px;
  padding: 0 18px;
  border: 0;
  border-radius: 15px;
  font-weight: 900;
  background: linear-gradient(135deg, var(--accent), var(--accent-2));
  box-shadow: 0 12px 32px rgba(124, 92, 255, 0.3);
}

.mode-btn, .danger-btn {
  height: 42px;
  padding: 0 14px;
  border-radius: 15px;
  font-weight: 850;
}

.danger-btn { color: #ffdce3; }

.tabbar {
  display: flex;
  gap: 9px;
  overflow-x: auto;
  scrollbar-width: none;
  padding: 2px 2px 4px;
  animation: fade-up 480ms ease both;
}

.tabbar::-webkit-scrollbar { display: none; }

.tab {
  min-width: 150px;
  max-width: 280px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 11px;
  border: 1px solid var(--border);
  background: rgba(255, 255, 255, 0.05);
  color: var(--muted);
  border-radius: 17px;
  cursor: pointer;
  transition: transform var(--fast), background var(--fast), border-color var(--fast), color var(--fast);
}

.tab:hover {
  transform: translateY(-1px);
  background: rgba(255, 255, 255, 0.1);
}

.tab.active {
  color: var(--text);
  border-color: rgba(124, 92, 255, 0.55);
  background: rgba(24, 30, 52, 0.92);
}

.tab-favicon {
  width: 20px;
  height: 20px;
  display: grid;
  place-items: center;
}

.tab-title {
  flex: 1;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  font-size: 13px;
  font-weight: 800;
}

.tab-close {
  width: 24px;
  height: 24px;
  border: 0;
  border-radius: 9px;
  color: var(--muted);
  background: transparent;
  cursor: pointer;
}

.tab-close:hover {
  color: white;
  background: rgba(255, 255, 255, 0.12);
}

.main {
  min-height: 0;
  display: grid;
  grid-template-columns: 1fr;
  animation: fade-up 520ms ease both;
}

.viewer {
  min-height: 0;
  border: 1px solid var(--border);
  background: var(--panel);
  backdrop-filter: blur(24px);
  border-radius: var(--radius-xl);
  box-shadow: var(--shadow);
  overflow: hidden;
  display: grid;
  grid-template-rows: auto 1fr;
}

.viewer-toolbar {
  min-height: 58px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px;
  border-bottom: 1px solid var(--border);
}

.status-pill {
  flex: 1;
  min-width: 0;
  padding: 11px 14px;
  border-radius: 16px;
  color: var(--muted);
  background: rgba(0, 0, 0, 0.25);
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.toolbar-hint {
  color: var(--muted-2);
  font-size: 13px;
  white-space: nowrap;
}

.viewer-body {
  min-height: 0;
  position: relative;
  overflow: hidden;
}

.home-view, .search-view, .reader-view, .browser-view {
  position: absolute;
  inset: 0;
}

.home-view {
  display: grid;
  place-items: center;
  padding: 28px;
  overflow: auto;
}

.hero-card {
  width: min(980px, 100%);
  padding: 36px;
  border: 1px solid var(--border);
  border-radius: var(--radius-xl);
  background: radial-gradient(circle at top left, rgba(124, 92, 255, 0.22), transparent 40%), rgba(0, 0, 0, 0.23);
  animation: pop 460ms ease both;
}

.hero-badge {
  display: inline-flex;
  margin-bottom: 18px;
  padding: 8px 12px;
  border: 1px solid var(--border);
  border-radius: 999px;
  color: var(--muted);
  background: rgba(255, 255, 255, 0.06);
  font-size: 13px;
}

.hero-card h1 {
  max-width: 760px;
  margin: 0;
  font-size: clamp(38px, 6vw, 78px);
  letter-spacing: -0.07em;
  line-height: 0.95;
  background: linear-gradient(135deg, white, #a9b3ff, #00d4ff);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}

.hero-card p {
  max-width: 760px;
  margin: 20px 0 0;
  color: var(--muted);
  line-height: 1.7;
}

.feature-grid {
  margin-top: 25px;
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px;
}

.feature-card {
  padding: 16px;
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  background: rgba(255, 255, 255, 0.06);
}

.feature-card strong {
  display: block;
  margin-bottom: 6px;
}

.feature-card span {
  color: var(--muted);
  font-size: 13px;
  line-height: 1.45;
}

.search-view {
  display: none;
  overflow: auto;
  padding: 22px;
}

.search-view.visible {
  display: block;
  animation: fade-up 240ms ease both;
}

.search-page {
  max-width: 1200px;
  margin: 0 auto;
}

.search-heading {
  margin-bottom: 16px;
}

.search-heading h1 {
  margin: 0;
  font-size: 34px;
  letter-spacing: -0.04em;
}

.search-heading p {
  margin: 5px 0 0;
  color: var(--muted);
}

.result-grid {
  display: grid;
  gap: 12px;
}

.result-card {
  padding: 18px;
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  background: rgba(0, 0, 0, 0.2);
  cursor: pointer;
  transition: transform var(--fast), background var(--fast), border-color var(--fast);
}

.result-card:hover {
  transform: translateY(-2px);
  background: var(--card-hover);
  border-color: var(--border-strong);
}

.result-title {
  font-size: 19px;
  font-weight: 900;
  line-height: 1.35;
}

.result-url {
  margin-top: 6px;
  color: var(--good);
  font-size: 13px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.result-body {
  margin-top: 9px;
  color: var(--muted);
  line-height: 1.55;
  font-size: 14px;
}

.result-actions {
  margin-top: 13px;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.small-btn {
  padding: 9px 12px;
  border-radius: 13px;
  font-size: 13px;
  font-weight: 850;
}

.reader-view {
  display: none;
  overflow: auto;
  padding: 28px;
}

.reader-view.visible {
  display: block;
  animation: fade-up 240ms ease both;
}

.reader-card {
  max-width: 980px;
  margin: 0 auto;
  padding: 32px;
  border: 1px solid var(--border);
  border-radius: var(--radius-xl);
  background: rgba(0, 0, 0, 0.28);
}

.reader-card h1 {
  margin: 0 0 12px;
  font-size: 38px;
  letter-spacing: -0.04em;
}

.reader-url {
  margin-bottom: 24px;
  color: var(--good);
  font-size: 13px;
  word-break: break-all;
}

.reader-card p {
  color: #dce2f7;
  line-height: 1.75;
  font-size: 16px;
}

.browser-view {
  display: none;
  background: #05070d;
}

.browser-view.visible { display: block; }

#browserFrame {
  width: 100%;
  height: 100%;
  border: 0;
  background: white;
}

.loader {
  position: absolute;
  top: 76px;
  left: 50%;
  z-index: 30;
  transform: translateX(-50%);
  display: none;
  align-items: center;
  gap: 10px;
  padding: 11px 15px;
  border: 1px solid var(--border);
  border-radius: 999px;
  background: var(--panel-strong);
  box-shadow: var(--shadow);
}

.loader.visible {
  display: flex;
  animation: fade-in 160ms ease both;
}

.spinner {
  width: 18px;
  height: 18px;
  border: 3px solid rgba(255, 255, 255, 0.16);
  border-top-color: var(--accent-2);
  border-radius: 50%;
  animation: spin 760ms linear infinite;
}

.empty-results {
  min-height: 320px;
  display: grid;
  place-items: center;
  text-align: center;
  color: var(--muted);
  border: 1px solid var(--border);
  border-radius: var(--radius-xl);
  background: rgba(0, 0, 0, 0.22);
}

.toast {
  position: fixed;
  right: 22px;
  bottom: 100px;
  z-index: 100;
  display: none;
  max-width: 400px;
  padding: 14px 16px;
  border: 1px solid var(--border);
  border-radius: 18px;
  background: var(--panel-strong);
  box-shadow: var(--shadow);
}

.toast.visible {
  display: block;
  animation: toast-in 220ms ease both;
}

.focus-toggle {
  position: fixed;
  right: 22px;
  bottom: 22px;
  z-index: 120;
  width: 68px;
  height: 68px;
  border: 1px solid rgba(255, 255, 255, 0.22);
  border-radius: 24px;
  color: white;
  background: linear-gradient(135deg, var(--accent), var(--accent-2));
  box-shadow: 0 22px 60px rgba(124, 92, 255, 0.45);
  font-size: 28px;
  font-weight: 950;
  cursor: pointer;
  transition: transform var(--fast), filter var(--fast), border-radius var(--fast);
}

.focus-toggle:hover {
  transform: translateY(-3px) scale(1.03);
  filter: brightness(1.08);
}

body.focus-mode .app {
  padding: 0;
  gap: 0;
  grid-template-rows: 1fr;
}

body.focus-mode .topbar,
body.focus-mode .tabbar {
  display: none;
}

body.focus-mode .viewer {
  border-radius: 0;
  border: 0;
}

body.focus-mode .viewer-toolbar {
  min-height: 46px;
  padding: 6px 82px 6px 8px;
  background: rgba(8, 11, 22, 0.9);
}

body.focus-mode .toolbar-hint { display: none; }
body.focus-mode .main { min-height: 100vh; }

body.focus-mode .focus-toggle {
  right: 14px;
  bottom: 14px;
  width: 58px;
  height: 58px;
  border-radius: 20px;
  font-size: 24px;
}

@keyframes drop-in {
  from { opacity: 0; transform: translateY(-18px); }
  to { opacity: 1; transform: none; }
}

@keyframes fade-up {
  from { opacity: 0; transform: translateY(14px); }
  to { opacity: 1; transform: none; }
}

@keyframes fade-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

@keyframes pop {
  from { opacity: 0; transform: scale(0.96); }
  to { opacity: 1; transform: scale(1); }
}

@keyframes toast-in {
  from { opacity: 0; transform: translateY(12px) scale(0.98); }
  to { opacity: 1; transform: none; }
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

@media (max-width: 1150px) {
  .topbar { flex-wrap: wrap; }
  .address-shell { order: 5; flex-basis: 100%; }
  .brand { flex: 1; }
  .toolbar-hint { display: none; }
}

@media (max-width: 700px) {
  .app { padding: 8px; }
  .brand-subtitle, .brand-text { display: none; }
  .feature-grid { grid-template-columns: 1fr; }
  .hero-card { padding: 22px; }
  .right-actions { flex-wrap: wrap; }
  .mode-btn, .danger-btn { padding: 0 10px; }
}
EOF

cat > public/app.js <<'EOF'
"use strict";

const $ = (id) => document.getElementById(id);

const els = {
  address: $("addressInput"),
  tabBar: $("tabBar"),
  status: $("statusText"),
  home: $("homeView"),
  search: $("searchView"),
  reader: $("readerView"),
  browser: $("browserView"),
  frame: $("browserFrame"),
  loader: $("loader"),
  toast: $("toast"),
  focusBtn: $("focusBtn")
};

const state = {
  tabs: [],
  activeId: null
};

function uid() {
  return crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2);
}

function clean(value) {
  return String(value || "").trim();
}

function toast(message) {
  els.toast.textContent = message;
  els.toast.classList.add("visible");
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => els.toast.classList.remove("visible"), 2800);
}

function loading(value) {
  els.loader.classList.toggle("visible", Boolean(value));
}

function isProbablyUrl(value) {
  const text = clean(value);
  if (text.startsWith("http://") || text.startsWith("https://")) return true;
  if (text.includes(" ")) return false;
  return text.includes(".") && !text.startsWith(".");
}

function normalizeUrl(value) {
  const text = clean(value);
  if (text.startsWith("http://") || text.startsWith("https://")) return text;
  return `https://${text}`;
}

function hostFromUrl(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "Page";
  }
}

function activeTab() {
  return state.tabs.find((tab) => tab.id === state.activeId) || null;
}

function createTab() {
  const tab = {
    id: uid(),
    title: "New Tab",
    url: "",
    mode: "home",
    results: [],
    reader: null,
    history: [],
    historyIndex: -1
  };

  state.tabs.push(tab);
  state.activeId = tab.id;
  render();
}

function closeTab(id) {
  if (state.tabs.length <= 1) {
    state.tabs = [];
    createTab();
    return;
  }

  const oldIndex = state.tabs.findIndex((tab) => tab.id === id);
  state.tabs = state.tabs.filter((tab) => tab.id !== id);

  if (state.activeId === id) {
    const next = state.tabs[Math.max(0, oldIndex - 1)];
    state.activeId = next.id;
  }

  render();
}

function currentSnapshot(tab) {
  return {
    title: tab.title,
    url: tab.url,
    mode: tab.mode,
    results: tab.results,
    reader: tab.reader
  };
}

function pushHistory(tab, snapshot) {
  tab.history = tab.history.slice(0, tab.historyIndex + 1);
  tab.history.push(JSON.parse(JSON.stringify(snapshot)));
  tab.historyIndex = tab.history.length - 1;
}

function applySnapshot(tab, snapshot) {
  tab.title = snapshot.title || "New Tab";
  tab.url = snapshot.url || "";
  tab.mode = snapshot.mode || "home";
  tab.results = snapshot.results || [];
  tab.reader = snapshot.reader || null;
  render();
}

function setMode(mode) {
  els.home.style.display = mode === "home" ? "grid" : "none";
  els.search.classList.toggle("visible", mode === "search");
  els.reader.classList.toggle("visible", mode === "reader");
  els.browser.classList.toggle("visible", mode === "browser");
}

function render() {
  renderTabs();
  renderActive();
}

function renderTabs() {
  els.tabBar.innerHTML = "";

  for (const tab of state.tabs) {
    const tabEl = document.createElement("div");
    tabEl.className = "tab" + (tab.id === state.activeId ? " active" : "");

    const icon = document.createElement("div");
    icon.className = "tab-favicon";
    icon.textContent =
      tab.mode === "reader" ? "📄" :
      tab.mode === "browser" ? "🌐" :
      tab.mode === "search" ? "⌕" :
      "◇";

    const title = document.createElement("div");
    title.className = "tab-title";
    title.textContent = tab.title || "New Tab";

    const close = document.createElement("button");
    close.className = "tab-close";
    close.textContent = "×";

    tabEl.onclick = () => {
      state.activeId = tab.id;
      render();
    };

    close.onclick = (event) => {
      event.stopPropagation();
      closeTab(tab.id);
    };

    tabEl.appendChild(icon);
    tabEl.appendChild(title);
    tabEl.appendChild(close);
    els.tabBar.appendChild(tabEl);
  }
}

function renderActive() {
  const tab = activeTab();
  if (!tab) return;

  els.address.value = tab.url || "";
  els.status.textContent = tab.url || "Ready.";
  setMode(tab.mode);

  if (tab.mode === "search") renderSearchPage(tab);
  if (tab.mode === "reader") renderReader(tab.reader);

  if (tab.mode === "browser" && tab.url) {
    const proxyUrl = `/api/proxy?url=${encodeURIComponent(tab.url)}`;
    if (els.frame.dataset.currentUrl !== tab.url) {
      els.frame.dataset.currentUrl = tab.url;
      els.frame.src = proxyUrl;
    }
  }
}

function renderSearchPage(tab) {
  els.search.innerHTML = "";

  const page = document.createElement("div");
  page.className = "search-page";

  const heading = document.createElement("div");
  heading.className = "search-heading";

  const h1 = document.createElement("h1");
  h1.textContent = `Search: ${tab.url}`;

  const p = document.createElement("p");
  p.textContent = "Results are shown in the big main renderer.";

  heading.appendChild(h1);
  heading.appendChild(p);
  page.appendChild(heading);

  if (!tab.results || !tab.results.length) {
    const empty = document.createElement("div");
    empty.className = "empty-results";
    empty.textContent = "No results found.";
    page.appendChild(empty);
    els.search.appendChild(page);
    return;
  }

  const grid = document.createElement("div");
  grid.className = "result-grid";

  for (const result of tab.results) {
    const card = document.createElement("article");
    card.className = "result-card";

    const title = document.createElement("div");
    title.className = "result-title";
    title.textContent = result.title || "No title";

    const url = document.createElement("div");
    url.className = "result-url";
    url.textContent = result.displayUrl || result.url || "";

    const body = document.createElement("div");
    body.className = "result-body";
    body.textContent = result.body || "";

    const actions = document.createElement("div");
    actions.className = "result-actions";

    const browserBtn = document.createElement("button");
    browserBtn.className = "small-btn";
    browserBtn.textContent = "Browser";
    browserBtn.onclick = (event) => {
      event.stopPropagation();
      openBrowser(result.url);
    };

    const readerBtn = document.createElement("button");
    readerBtn.className = "small-btn";
    readerBtn.textContent = "Reader";
    readerBtn.onclick = (event) => {
      event.stopPropagation();
      openReader(result.url);
    };

    const openBtn = document.createElement("button");
    openBtn.className = "small-btn";
    openBtn.textContent = "Open";
    openBtn.onclick = (event) => {
      event.stopPropagation();
      window.open(result.url, "_blank", "noopener,noreferrer");
    };

    actions.appendChild(browserBtn);
    actions.appendChild(readerBtn);
    actions.appendChild(openBtn);

    card.onclick = () => openBrowser(result.url);

    card.appendChild(title);
    card.appendChild(url);
    card.appendChild(body);
    card.appendChild(actions);

    grid.appendChild(card);
  }

  page.appendChild(grid);
  els.search.appendChild(page);
}

function renderReader(reader) {
  els.reader.innerHTML = "";
  if (!reader) return;

  const card = document.createElement("article");
  card.className = "reader-card";

  const title = document.createElement("h1");
  title.textContent = reader.title || "Reader";

  const url = document.createElement("div");
  url.className = "reader-url";
  url.textContent = reader.url || "";

  card.appendChild(title);
  card.appendChild(url);

  if (!reader.parts || !reader.parts.length) {
    const p = document.createElement("p");
    p.textContent = "No readable text found. Try Browser or Open.";
    card.appendChild(p);
  } else {
    for (const text of reader.parts) {
      const p = document.createElement("p");
      p.textContent = text;
      card.appendChild(p);
    }
  }

  els.reader.appendChild(card);
}

async function searchWeb(query, push = true) {
  const tab = activeTab();
  if (!tab) return;

  loading(true);
  els.status.textContent = "Searching...";

  try {
    const response = await fetch("/api/search", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store"
      },
      body: JSON.stringify({ q: query })
    });

    const data = await response.json();
    if (!data.ok) throw new Error(data.error || "Search failed.");

    tab.title = query.slice(0, 34) || "Search";
    tab.url = query;
    tab.mode = "search";
    tab.results = data.results || [];
    tab.reader = null;

    if (push) pushHistory(tab, currentSnapshot(tab));
    render();
  } catch (error) {
    toast(error.message);
    els.status.textContent = "Search failed.";
  } finally {
    loading(false);
  }
}

async function openReader(rawUrl, push = true) {
  const tab = activeTab();
  if (!tab) return;

  const url = normalizeUrl(rawUrl);
  loading(true);
  els.status.textContent = "Loading reader...";

  try {
    const response = await fetch("/api/reader", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store"
      },
      body: JSON.stringify({ url })
    });

    const data = await response.json();
    if (!data.ok) throw new Error(data.error || "Reader failed.");

    tab.title = data.title || hostFromUrl(url);
    tab.url = data.url || url;
    tab.mode = "reader";
    tab.reader = {
      title: data.title,
      url: data.url || url,
      parts: data.parts || []
    };

    if (push) pushHistory(tab, currentSnapshot(tab));
    render();
  } catch (error) {
    toast(error.message);
    els.status.textContent = "Reader failed. Try Browser or Open.";
  } finally {
    loading(false);
  }
}

function openBrowser(rawUrl, push = true) {
  const tab = activeTab();
  if (!tab) return;

  const url = normalizeUrl(rawUrl);

  tab.title = hostFromUrl(url);
  tab.url = url;
  tab.mode = "browser";
  tab.reader = null;

  els.frame.dataset.currentUrl = "";
  els.frame.src = `/api/proxy?url=${encodeURIComponent(url)}`;

  if (push) pushHistory(tab, currentSnapshot(tab));
  render();
}

function go() {
  const value = clean(els.address.value);
  if (!value) return;

  if (isProbablyUrl(value)) openBrowser(value);
  else searchWeb(value);
}

function goHome(push = true) {
  const tab = activeTab();
  if (!tab) return;

  tab.title = "New Tab";
  tab.url = "";
  tab.mode = "home";
  tab.results = [];
  tab.reader = null;
  els.frame.removeAttribute("src");
  els.frame.dataset.currentUrl = "";

  if (push) pushHistory(tab, currentSnapshot(tab));
  render();
}

function reload() {
  const tab = activeTab();
  if (!tab) return;

  if (tab.mode === "browser" && tab.url) {
    els.frame.dataset.currentUrl = "";
    els.frame.src = `/api/proxy?url=${encodeURIComponent(tab.url)}`;
  } else if (tab.mode === "reader" && tab.url) {
    openReader(tab.url, false);
  } else if (tab.mode === "search" && tab.url) {
    searchWeb(tab.url, false);
  }
}

function back() {
  const tab = activeTab();
  if (!tab || tab.historyIndex <= 0) return;
  tab.historyIndex -= 1;
  applySnapshot(tab, tab.history[tab.historyIndex]);
}

function forward() {
  const tab = activeTab();
  if (!tab || tab.historyIndex >= tab.history.length - 1) return;
  tab.historyIndex += 1;
  applySnapshot(tab, tab.history[tab.historyIndex]);
}

function clearSession() {
  els.frame.removeAttribute("src");
  els.frame.dataset.currentUrl = "";
  state.tabs = [];
  createTab();
  toast("Temporary in-memory session cleared.");
}

function toggleFocusMode() {
  const active = document.body.classList.toggle("focus-mode");
  els.focusBtn.textContent = active ? "×" : "⛶";
  els.focusBtn.title = active ? "Exit focus mode" : "Fullscreen renderer";

  if (active && document.documentElement.requestFullscreen) {
    document.documentElement.requestFullscreen().catch(() => {});
  }

  if (!active && document.fullscreenElement && document.exitFullscreen) {
    document.exitFullscreen().catch(() => {});
  }
}

$("goBtn").onclick = go;
$("backBtn").onclick = back;
$("forwardBtn").onclick = forward;
$("reloadBtn").onclick = reload;
$("homeBtn").onclick = () => goHome();
$("newTabBtn").onclick = createTab;
$("clearBtn").onclick = clearSession;
$("focusBtn").onclick = toggleFocusMode;

$("readerBtn").onclick = () => {
  const tab = activeTab();
  const value = clean(els.address.value || tab?.url || "");
  if (!value || !isProbablyUrl(value)) {
    toast("Enter a URL first.");
    return;
  }
  openReader(value);
};

$("browserBtn").onclick = () => {
  const tab = activeTab();
  const value = clean(els.address.value || tab?.url || "");
  if (!value || !isProbablyUrl(value)) {
    toast("Enter a URL first.");
    return;
  }
  openBrowser(value);
};

$("openBtn").onclick = () => {
  const value = clean(els.address.value);
  if (!value) {
    toast("Enter a URL or search first.");
    return;
  }

  const url = isProbablyUrl(value)
    ? normalizeUrl(value)
    : `https://duckduckgo.com/?q=${encodeURIComponent(value)}`;

  window.open(url, "_blank", "noopener,noreferrer");
};

els.address.addEventListener("keydown", (event) => {
  if (event.key === "Enter") go();
});

window.addEventListener("message", (event) => {
  if (event.data?.type === "codespace-browser-navigate" && event.data.url) {
    openBrowser(event.data.url);
  }
});

document.addEventListener("fullscreenchange", () => {
  if (!document.fullscreenElement && document.body.classList.contains("focus-mode")) {
    document.body.classList.remove("focus-mode");
    els.focusBtn.textContent = "⛶";
    els.focusBtn.title = "Fullscreen renderer";
  }
});

createTab();
EOF

cat > .devcontainer/devcontainer.json <<'EOF'
{
  "name": "Big Renderer Codespace Browser",
  "image": "mcr.microsoft.com/devcontainers/javascript-node:1-22-bookworm",
  "postCreateCommand": "npm install --no-package-lock",
  "forwardPorts": [7860],
  "portsAttributes": {
    "7860": {
      "label": "Big Renderer Browser",
      "onAutoForward": "openBrowser"
    }
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

cat > .gitignore <<'EOF'
node_modules/
package-lock.json
npm-debug.log*
.DS_Store
.env
.cache/
EOF

echo ""
echo "Installing..."
npm install --no-package-lock

echo ""
echo "Starting browser app..."
echo "Open Codespaces port 7860 after it starts."
npm start
