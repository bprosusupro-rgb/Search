"use strict";

const $ = (id) => document.getElementById(id);

const els = {
  address: $("addressInput"),
  tabBar: $("tabBar"),
  status: $("statusText"),
  home: $("homeView"),
  search: $("searchView"),
  reader: $("readerView"),
  proxy: $("proxyView"),
  real: $("realView"),
  proxyFrame: $("proxyFrame"),
  realFrame: $("realFrame"),
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
  toast._timer = setTimeout(() => els.toast.classList.remove("visible"), 3200);
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

function ensureRealFrame() {
  if (!els.realFrame.src) {
    els.realFrame.src = "/real.html";
  }
}

function setMode(mode) {
  els.home.style.display = mode === "home" ? "grid" : "none";
  els.search.classList.toggle("visible", mode === "search");
  els.reader.classList.toggle("visible", mode === "reader");
  els.proxy.classList.toggle("visible", mode === "proxy");
  els.real.classList.toggle("visible", mode === "real");

  if (mode === "real") ensureRealFrame();
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
      tab.mode === "real" ? "⚡" :
      tab.mode === "proxy" ? "🌐" :
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

  if (tab.mode === "proxy" && tab.url) {
    const proxyUrl = `/api/proxy?url=${encodeURIComponent(tab.url)}`;
    if (els.proxyFrame.dataset.currentUrl !== tab.url) {
      els.proxyFrame.dataset.currentUrl = tab.url;
      els.proxyFrame.src = proxyUrl;
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
  p.textContent = "Click a result to open it in Real Chromium mode.";

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

    const realBtn = document.createElement("button");
    realBtn.className = "small-btn";
    realBtn.textContent = "Real";
    realBtn.onclick = (event) => {
      event.stopPropagation();
      openReal(result.url);
    };

    const proxyBtn = document.createElement("button");
    proxyBtn.className = "small-btn";
    proxyBtn.textContent = "Proxy";
    proxyBtn.onclick = (event) => {
      event.stopPropagation();
      openProxy(result.url);
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

    actions.appendChild(realBtn);
    actions.appendChild(proxyBtn);
    actions.appendChild(readerBtn);
    actions.appendChild(openBtn);

    card.onclick = () => openReal(result.url);

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
    p.textContent = "No readable text found. Try Real or Open.";
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

async function openReal(rawUrl, push = true) {
  const tab = activeTab();
  if (!tab) return;

  const url = normalizeUrl(rawUrl);
  ensureRealFrame();

  tab.title = hostFromUrl(url);
  tab.url = url;
  tab.mode = "real";
  tab.reader = null;

  if (push) pushHistory(tab, currentSnapshot(tab));
  render();

  loading(true);
  els.status.textContent = "Opening in real Chromium...";

  try {
    const response = await fetch("/api/real/navigate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store"
      },
      body: JSON.stringify({ url })
    });

    const data = await response.json();
    if (!data.ok) throw new Error(data.error || "Real Chromium navigation failed.");

    els.status.textContent = url;
  } catch (error) {
    toast(error.message);
    els.status.textContent = "Real Chromium failed. Wait 2 seconds and press Real again.";
  } finally {
    loading(false);
  }
}

function openProxy(rawUrl, push = true) {
  const tab = activeTab();
  if (!tab) return;

  const url = normalizeUrl(rawUrl);

  tab.title = hostFromUrl(url);
  tab.url = url;
  tab.mode = "proxy";
  tab.reader = null;

  els.proxyFrame.dataset.currentUrl = "";
  els.proxyFrame.src = `/api/proxy?url=${encodeURIComponent(url)}`;

  if (push) pushHistory(tab, currentSnapshot(tab));
  render();
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
    els.status.textContent = "Reader failed. Try Real or Open.";
  } finally {
    loading(false);
  }
}

function go() {
  const value = clean(els.address.value);
  if (!value) return;

  if (isProbablyUrl(value)) openReal(value);
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

  els.proxyFrame.removeAttribute("src");
  els.proxyFrame.dataset.currentUrl = "";

  if (push) pushHistory(tab, currentSnapshot(tab));
  render();
}

function reload() {
  const tab = activeTab();
  if (!tab) return;

  if (tab.mode === "real" && tab.url) {
    openReal(tab.url, false);
  } else if (tab.mode === "proxy" && tab.url) {
    els.proxyFrame.dataset.currentUrl = "";
    els.proxyFrame.src = `/api/proxy?url=${encodeURIComponent(tab.url)}`;
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
  els.proxyFrame.removeAttribute("src");
  els.proxyFrame.dataset.currentUrl = "";
  state.tabs = [];
  createTab();
  toast("Temporary UI session cleared. Browser cookies reset on app restart.");
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

$("realBtn").onclick = () => {
  const tab = activeTab();
  const value = clean(els.address.value || tab?.url || "");

  if (!value || !isProbablyUrl(value)) {
    ensureRealFrame();
    tab.mode = "real";
    render();
    toast("Real Chromium opened. Use its address bar or enter a URL above.");
    return;
  }

  openReal(value);
};

$("proxyBtn").onclick = () => {
  const tab = activeTab();
  const value = clean(els.address.value || tab?.url || "");

  if (!value || !isProbablyUrl(value)) {
    toast("Enter a URL first.");
    return;
  }

  openProxy(value);
};

$("readerBtn").onclick = () => {
  const tab = activeTab();
  const value = clean(els.address.value || tab?.url || "");

  if (!value || !isProbablyUrl(value)) {
    toast("Enter a URL first.");
    return;
  }

  openReader(value);
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
    openReal(event.data.url);
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

setTimeout(() => {
  ensureRealFrame();
  els.status.textContent = "Ready. URLs open in Real Chromium mode.";
}, 1000);
