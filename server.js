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
  setHeaders: (res) => {
    res.setHeader("Cache-Control", "no-store");
  }
}));

function cleanText(value = "") {
  return String(value).replace(/\s+/g, " ").trim();
}

function normalizeUrl(raw) {
  const value = cleanText(raw);

  if (!value) {
    throw new Error("Empty URL.");
  }

  if (value.startsWith("http://") || value.startsWith("https://")) {
    return value;
  }

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
  ) {
    return true;
  }

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
    if (host === "::1") return true;
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

    if (urlText.startsWith("//")) {
      urlText = `https:${urlText}`;
    }

    if (urlText.startsWith("/")) {
      urlText = `https://duckduckgo.com${urlText}`;
    }

    const url = new URL(urlText);

    const uddg = url.searchParams.get("uddg");
    if (uddg) {
      return decodeURIComponent(uddg);
    }

    return url.href;
  } catch {
    return href || "";
  }
}

async function fetchText(url, options = {}) {
  const response = await fetch(url, {
    redirect: "follow",
    headers: {
      "User-Agent": "Mozilla/5.0 CodespaceBrowser/1.0 Chrome/124 Safari/537.36",
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

    if (!q) {
      return res.status(400).json({ ok: false, error: "Search is empty." });
    }

    const searchUrl = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(q)}`;
    const page = await fetchText(searchUrl, { timeoutMs: 15000 });

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

      results.push({
        title,
        url: href,
        displayUrl,
        body
      });
    });

    res.json({
      ok: true,
      q,
      results: results.slice(0, 15)
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

app.post("/api/reader", async (req, res) => {
  try {
    const url = safePublicUrl(req.body?.url || "");
    const page = await fetchText(url.href, { timeoutMs: 15000 });

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
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

app.get("/api/proxy", async (req, res) => {
  try {
    const url = safePublicUrl(req.query.url || "");
    const page = await fetchText(url.href, { timeoutMs: 15000 });

    if (!page.ok) {
      return res.status(502).send(`Could not load page: ${page.status} ${page.statusText}`);
    }

    if (!page.contentType.includes("text/html")) {
      res.setHeader("Content-Type", "text/plain; charset=utf-8");
      return res.send("This preview only supports HTML pages. Use Open instead.");
    }

    const $ = cheerio.load(page.text);

    $("meta[http-equiv='Content-Security-Policy']").remove();

    if ($("head").length === 0) {
      $("html").prepend("<head></head>");
    }

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
  console.log(" Codespace GUI Browser running");
  console.log(` Local URL: http://127.0.0.1:${PORT}`);
  console.log(` Codespaces port: ${PORT}`);
  console.log(" Open the forwarded port in the Ports tab.");
  console.log("====================================================");
  console.log("");
});
