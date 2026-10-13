import RFB from "/novnc/core/rfb.js";

const screen = document.getElementById("screen");
const viewer = document.getElementById("viewer");
const connection = document.getElementById("connection");
const connectionText = document.getElementById("connectionText");
const addressInput = document.getElementById("addressInput");
const keyboardBox = document.getElementById("keyboardBox");
const toastEl = document.getElementById("toast");
const modeStatus = document.getElementById("modeStatus");
const qualitySelect = document.getElementById("qualitySelect");

function toast(text) {
  toastEl.textContent = text;
  toastEl.classList.add("visible");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => toastEl.classList.remove("visible"), 2200);
}

async function postJson(url, body) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.ok) throw new Error(data.error || "Request failed.");
  return data;
}

const protocol = location.protocol === "https:" ? "wss:" : "ws:";
const rfb = new RFB(screen, `${protocol}//${location.host}/websockify`, { shared: true });
rfb.scaleViewport = true;
rfb.resizeSession = true;
rfb.clipViewport = false;
rfb.dragViewport = false;
rfb.showDotCursor = true;
rfb.qualityLevel = 7;
rfb.compressionLevel = 2;
rfb.background = "#080a0d";

rfb.addEventListener("connect", () => {
  connection.classList.add("connected");
  connectionText.textContent = "Connected · remote browser ready";
  setTimeout(() => connection.classList.add("hidden"), 2200);
});

rfb.addEventListener("disconnect", (event) => {
  connection.classList.remove("hidden", "connected");
  connectionText.textContent = event.detail?.clean ? "Session ended" : "Connection lost · refresh to reconnect";
  if (!event.detail?.clean) toast("Connection to the remote browser was lost.");
});

rfb.addEventListener("credentialsrequired", () => {
  connectionText.textContent = "Remote browser needs credentials";
});

rfb.addEventListener("securityfailure", (event) => {
  connectionText.textContent = event.detail?.reason || "Connection security error";
});

async function navigate(event) {
  event?.preventDefault();
  const value = addressInput.value.trim();
  if (!value) return;
  try {
    toast("Opening…");
    const data = await postJson("/api/navigate", { url: value });
    addressInput.value = data.url || value;
    toast("Page opened");
    if (keyboardBox.classList.contains("visible")) closeKeyboard();
  } catch (error) {
    toast(error.message);
  }
}

document.getElementById("addressForm").addEventListener("submit", navigate);

document.getElementById("reloadBtn").addEventListener("click", async () => {
  try { await postJson("/api/key", { key: "F5" }); }
  catch { toast("Could not reload the remote page."); }
});

document.getElementById("focusBtn").addEventListener("click", () => {
  document.body.classList.toggle("focus");
  rfb.focus();
});
document.getElementById("immersiveExitBtn").addEventListener("click", () => {
  document.body.classList.remove("focus");
  rfb.focus();
});

document.getElementById("fullscreenBtn").addEventListener("click", async () => {
  try {
    if (!document.fullscreenElement) await viewer.requestFullscreen();
    else await document.exitFullscreen();
  } catch { toast("Fullscreen is unavailable in this browser."); }
});

function closeKeyboard() {
  keyboardBox.classList.remove("visible");
  keyboardBox.blur();
  document.getElementById("keyboardBtn").setAttribute("aria-label", "Open keyboard");
}

document.getElementById("keyboardBtn").addEventListener("click", () => {
  const opening = !keyboardBox.classList.contains("visible");
  if (!opening) return closeKeyboard();
  keyboardBox.classList.add("visible");
  document.getElementById("keyboardBtn").setAttribute("aria-label", "Close keyboard");
  keyboardBox.value = "";
  keyboardBox.focus({ preventScroll: true });
  toast("Type to send text to Chromium");
});

let textQueue = "";
let textTimer = 0;
let textSendChain = Promise.resolve();
function flushText() {
  clearTimeout(textTimer);
  textTimer = 0;
  const text = textQueue;
  textQueue = "";
  if (text) {
    textSendChain = textSendChain
      .then(() => postJson("/api/text", { text }))
      .catch(() => toast("Text could not be sent."));
  }
  return textSendChain;
}

keyboardBox.addEventListener("input", (event) => {
  if (event.inputType === "deleteContentBackward") {
    postJson("/api/key", { key: "Backspace" }).catch(() => {});
    keyboardBox.value = "";
    return;
  }
  const value = keyboardBox.value.replace(/[\r\n]/g, "");
  if (!value) return;
  textQueue += value;
  keyboardBox.value = "";
  clearTimeout(textTimer);
  textTimer = setTimeout(flushText, 45);
});

keyboardBox.addEventListener("keydown", async (event) => {
  const keys = { Enter: "Enter", Backspace: "Backspace", Tab: "Tab", Escape: "Escape" };
  if (!keys[event.key]) return;
  event.preventDefault();
  await flushText();
  await postJson("/api/key", { key: keys[event.key] }).catch(() => {});
  if (event.key === "Enter") keyboardBox.value = "";
});

function setMode(mode) {
  const buttons = {
    control: document.getElementById("controlModeBtn"),
    scroll: document.getElementById("scrollModeBtn"),
    watch: document.getElementById("watchModeBtn")
  };
  for (const [name, button] of Object.entries(buttons)) {
    button.classList.toggle("active", name === mode);
    button.setAttribute("aria-pressed", String(name === mode));
  }
  rfb.viewOnly = mode !== "control";
  document.body.classList.toggle("scroll-mode", mode === "scroll");
  modeStatus.textContent = mode === "scroll" ? "Swipe to scroll the remote page" : mode === "watch" ? "Viewing · remote input paused" : "Touch to move and tap";
  if (mode === "control") rfb.focus();
}

document.getElementById("controlModeBtn").addEventListener("click", () => setMode("control"));
document.getElementById("scrollModeBtn").addEventListener("click", () => setMode("scroll"));
document.getElementById("watchModeBtn").addEventListener("click", () => setMode("watch"));

let scrollPointer = null;
let scrollPoint = null;
let pendingScroll = null;
let scrollTimer = 0;
let scrollSending = false;
function sendPendingRemoteScroll() {
  scrollTimer = 0;
  if (scrollSending || !pendingScroll) return;
  const payload = pendingScroll;
  pendingScroll = null;
  scrollSending = true;
  postJson("/api/scroll", payload).catch(() => {}).finally(() => {
    scrollSending = false;
    if (pendingScroll && !scrollTimer) scrollTimer = setTimeout(sendPendingRemoteScroll, 20);
  });
}
function queueRemoteScroll(point, deltaX, deltaY) {
  if (Math.abs(deltaX) + Math.abs(deltaY) < 1) return;
  pendingScroll = {
    ...point,
    deltaX: (pendingScroll?.deltaX || 0) + deltaX,
    deltaY: (pendingScroll?.deltaY || 0) + deltaY
  };
  if (scrollTimer) return;
  scrollTimer = setTimeout(sendPendingRemoteScroll, 55);
}

screen.addEventListener("pointerdown", (event) => {
  if (document.body.classList.contains("scroll-mode") && event.pointerType === "touch") {
    event.preventDefault();
    event.stopPropagation();
    scrollPointer = event.pointerId;
    scrollPoint = { x: event.clientX, y: event.clientY };
    screen.setPointerCapture(event.pointerId);
  }
}, true);

screen.addEventListener("pointermove", (event) => {
  if (scrollPointer !== event.pointerId || !scrollPoint) return;
  event.preventDefault();
  event.stopPropagation();
  const dx = event.clientX - scrollPoint.x;
  const dy = event.clientY - scrollPoint.y;
  scrollPoint = { x: event.clientX, y: event.clientY };
  const bounds = screen.getBoundingClientRect();
  queueRemoteScroll({
    x: Math.max(0, Math.min(1, (event.clientX - bounds.left) / bounds.width)),
    y: Math.max(0, Math.min(1, (event.clientY - bounds.top) / bounds.height))
  }, -dx, -dy);
}, true);

function endRemoteScroll(event) {
  if (scrollPointer !== event.pointerId) return;
  event.preventDefault();
  event.stopPropagation();
  scrollPointer = null;
  scrollPoint = null;
}
screen.addEventListener("pointerup", endRemoteScroll, true);
screen.addEventListener("pointercancel", endRemoteScroll, true);
screen.addEventListener("lostpointercapture", endRemoteScroll, true);

const qualityModes = {
  fast: { quality: 4, compression: 1, label: "Fast video · lower latency" },
  balanced: { quality: 7, compression: 2, label: "Balanced stream quality" },
  sharp: { quality: 9, compression: 1, label: "Sharp stream quality" }
};
qualitySelect.addEventListener("change", () => {
  const mode = qualityModes[qualitySelect.value] || qualityModes.balanced;
  rfb.qualityLevel = mode.quality;
  rfb.compressionLevel = mode.compression;
  toast(mode.label);
});

function getWatchPortUrl() {
  const host = location.host;
  if (/-\d+\./.test(host)) return `${location.protocol}//${host.replace(/-\d+\./, "-7861.")}/watch.html`;
  if (/:\d+$/.test(host)) return `${location.protocol}//${host.replace(/:\d+$/, ":7861")}/watch.html`;
  return `${location.protocol}//${location.hostname}:7861/watch.html`;
}

document.getElementById("watchPortBtn").addEventListener("click", async () => {
  // Open synchronously from the tap so mobile popup blockers allow the new tab.
  window.open(getWatchPortUrl(), "_blank", "noopener,noreferrer");
  try {
    await postJson("/api/watch-mode", {});
    toast("Watch only opened in a new tab");
  } catch (error) {
    toast(error.message || "Watch tab failed.");
  }
});

document.getElementById("saveBtn").addEventListener("click", async () => {
  try {
    await postJson("/api/save-state", {});
    toast("Browser session saved");
  } catch (error) { toast(error.message || "Save failed."); }
});

document.getElementById("ytBackBtn").addEventListener("click", () => {
  postJson("/api/youtube", { action: "seek", seconds: -10 }).then(() => toast("Back 10 seconds")).catch(() => toast("No video found"));
});
document.getElementById("ytPlayBtn").addEventListener("click", () => {
  postJson("/api/youtube", { action: "togglePlay" }).then(() => toast("Play / pause")).catch(() => toast("No video found"));
});
document.getElementById("ytForwardBtn").addEventListener("click", () => {
  postJson("/api/youtube", { action: "seek", seconds: 10 }).then(() => toast("Forward 10 seconds")).catch(() => toast("No video found"));
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && rfb.connected) rfb.focus();
});
