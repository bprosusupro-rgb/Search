#!/usr/bin/env bash
set -e

echo "Patching CDP renderer to stop freezing on heavy pages..."

pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
sleep 1

if [ ! -f server.js ]; then
  echo "ERROR: server.js not found."
  exit 1
fi

if [ ! -f public/real.html ]; then
  echo "ERROR: public/real.html not found."
  exit 1
fi

cp server.js "server.js.backup-freeze-$(date +%s)"
cp public/real.html "public/real.html.backup-freeze-$(date +%s)"

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let s = fs.readFileSync("server.js", "utf8");

// Add streaming constants if missing
if (!s.includes("const STREAM_MAX_WIDTH")) {
  s = s.replace(
    `const DISPLAY_NUM = ":99";`,
    `const DISPLAY_NUM = ":99";

const STREAM_MAX_WIDTH = 1280;
const STREAM_MAX_HEIGHT = 760;
const STREAM_JPEG_QUALITY = 48;
const STREAM_EVERY_NTH_FRAME = 3;
const STREAM_MIN_FRAME_INTERVAL_MS = 90;
const CLIENT_MAX_BUFFERED_BYTES = 4 * 1024 * 1024;`
  );
}

// Make Chrome less likely to overload Codespaces
if (!s.includes("--disable-gpu")) {
  s = s.replace(
    `"--no-first-run",`,
    `"--disable-gpu",
      "--disable-software-rasterizer",
      "--disable-dev-shm-usage",
      "--disable-renderer-backgrounding",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--no-first-run",`
  );
}

// Replace startScreencast settings
s = s.replace(
  /await sendChrome\("Page\.startScreencast",\s*\{[\s\S]*?everyNthFrame:\s*\d+\s*\}\);/,
  `try {
        await sendChrome("Page.stopScreencast");
      } catch {}

      await sendChrome("Page.startScreencast", {
        format: "jpeg",
        quality: STREAM_JPEG_QUALITY,
        maxWidth: STREAM_MAX_WIDTH,
        maxHeight: STREAM_MAX_HEIGHT,
        everyNthFrame: STREAM_EVERY_NTH_FRAME
      });`
);

// Insert frame throttle variables in createCdpRenderer
if (!s.includes("let lastFrameSentAt = 0;")) {
  s = s.replace(
    `let nextId = 1;
  const pending = new Map();`,
    `let nextId = 1;
  let lastFrameSentAt = 0;
  let rendererPaused = false;
  let droppedFrames = 0;
  const pending = new Map();`
  );
}

// Replace screencast frame handler with throttled version
s = s.replace(
  /if \(msg\.method === "Page\.screencastFrame"\) \{[\s\S]*?try \{\s*await sendChrome\("Page\.screencastFrameAck", \{ sessionId \}\);\s*\} catch \{\}\s*\}/,
  `if (msg.method === "Page.screencastFrame") {
        const { data: imageData, metadata, sessionId } = msg.params;

        const now = Date.now();
        const clientTooFull = client.bufferedAmount > CLIENT_MAX_BUFFERED_BYTES;
        const tooSoon = now - lastFrameSentAt < STREAM_MIN_FRAME_INTERVAL_MS;

        if (!rendererPaused && !clientTooFull && !tooSoon && client.readyState === WebSocket.OPEN) {
          lastFrameSentAt = now;

          sendClient({
            type: "frame",
            image: imageData,
            metadata,
            droppedFrames
          });

          droppedFrames = 0;
        } else {
          droppedFrames++;
        }

        try {
          chrome.send(JSON.stringify({
            id: nextId++,
            method: "Page.screencastFrameAck",
            params: { sessionId }
          }));
        } catch {}
      }`
);

// Add pause/resume renderer messages if missing
if (!s.includes(`msg.type === "pauseRenderer"`)) {
  s = s.replace(
    `if (msg.type === "navigate") {`,
    `if (msg.type === "pauseRenderer") {
        rendererPaused = true;
        return;
      }

      if (msg.type === "resumeRenderer") {
        rendererPaused = false;
        return;
      }

      if (msg.type === "navigate") {`
  );
}

// More forgiving navigation timeout
s = s.replace(/}, 10000\);/g, `}, 20000);`);

fs.writeFileSync("server.js", s);
NODE

cat > public/real.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>Stable CDP Touch Renderer</title>
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
      max-width: calc(100vw - 24px);
      overflow-x: auto;
    }

    button {
      border: 1px solid rgba(255,255,255,0.18);
      color: white;
      background: rgba(255,255,255,0.09);
      border-radius: 13px;
      padding: 9px 11px;
      font: 800 12px system-ui, sans-serif;
      white-space: nowrap;
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
      max-width: min(680px, calc(100vw - 28px));
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
    <button id="pauseBtn">Pause</button>
    <button id="reconnectBtn">Reconnect</button>
  </div>

  <input id="keyboardBox" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" />

  <div id="hint">
    Stable mode: lower FPS prevents freezing. Tap = touch/click, drag = touch drag, two fingers = scroll. Pause can help while loading heavy pages.
  </div>

  <script>
    const canvas = document.getElementById("canvas");
    const ctx = canvas.getContext("2d", { alpha: false });
    const statusEl = document.getElementById("status");
    const keyboardBox = document.getElementById("keyboardBox");
    const touchBtn = document.getElementById("touchBtn");
    const mouseBtn = document.getElementById("mouseBtn");
    const pauseBtn = document.getElementById("pauseBtn");
    const reconnectBtn = document.getElementById("reconnectBtn");

    let ws;
    let mode = "touch";
    let paused = false;
    let drawing = false;
    let latestFrame = null;
    let lastDrawAt = 0;
    let frameCounter = 0;

    let lastFrameMeta = {
      deviceWidth: 1280,
      deviceHeight: 760
    };

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
      if (ws) {
        try { ws.close(); } catch {}
      }

      setStatus("Connecting...");

      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      ws = new WebSocket(`${protocol}//${location.host}/cdp-renderer`);

      ws.onopen = () => {
        setStatus("Connected to stable CDP renderer.", true);
        if (paused) send({ type: "pauseRenderer" });
      };

      ws.onmessage = (event) => {
        let msg;

        try {
          msg = JSON.parse(event.data);
        } catch {
          return;
        }

        if (msg.type === "status") {
          setStatus(msg.text, true);
        }

        if (msg.type === "error") {
          setStatus(msg.error || "Renderer error.");
        }

        if (msg.type === "frame") {
          latestFrame = msg;
          scheduleDraw();
        }
      };

      ws.onclose = () => {
        setStatus("Disconnected. Reconnecting...");
        setTimeout(connect, 1200);
      };
    }

    function scheduleDraw() {
      if (drawing) return;
      drawing = true;

      requestAnimationFrame(drawLatestFrame);
    }

    function resizeCanvas(width, height) {
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
    }

    function drawLatestFrame() {
      const msg = latestFrame;
      latestFrame = null;

      if (!msg || paused) {
        drawing = false;
        return;
      }

      const now = performance.now();

      if (now - lastDrawAt < 80) {
        drawing = false;
        if (latestFrame) scheduleDraw();
        return;
      }

      lastDrawAt = now;

      const img = new Image();

      img.onload = () => {
        lastFrameMeta = {
          deviceWidth: msg.metadata?.deviceWidth || msg.metadata?.viewportWidth || img.width || lastFrameMeta.deviceWidth,
          deviceHeight: msg.metadata?.deviceHeight || msg.metadata?.viewportHeight || img.height || lastFrameMeta.deviceHeight
        };

        resizeCanvas(img.width, img.height);
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

        frameCounter++;

        if (frameCounter % 30 === 0 && msg.droppedFrames) {
          setStatus(`Stable renderer active. Dropped ${msg.droppedFrames} old frames to avoid freezing.`, true);
        }

        drawing = false;

        if (latestFrame) {
          scheduleDraw();
        }
      };

      img.onerror = () => {
        drawing = false;
      };

      img.src = `data:image/jpeg;base64,${msg.image}`;
    }

    function pointFromEvent(event) {
      const rect = canvas.getBoundingClientRect();

      const rx = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
      const ry = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));

      return {
        id: event.pointerId || 1,
        x: Math.round(rx * (lastFrameMeta.deviceWidth || 1280)),
        y: Math.round(ry * (lastFrameMeta.deviceHeight || 760))
      };
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
        x: Math.round(rx * (lastFrameMeta.deviceWidth || 1280)),
        y: Math.round(ry * (lastFrameMeta.deviceHeight || 760))
      };
    }

    canvas.addEventListener("pointerdown", (event) => {
      event.preventDefault();

      try {
        canvas.setPointerCapture(event.pointerId);
      } catch {}

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
        send({ type: "tap", x: p.x, y: p.y });
        return;
      }

      send({ type: "touchStart", points: [p] });
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
            deltaX: -(now.x - lastTwoFinger.x) * 2.4,
            deltaY: -(now.y - lastTwoFinger.y) * 2.4
          });
        }

        lastTwoFinger = now;
        return;
      }

      if (mode === "touch" && event.pointerType !== "mouse") {
        send({ type: "touchMove", points: [p] });
      } else {
        send({ type: "mouseMove", x: p.x, y: p.y });
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
      const wasDoubleTapArea = now - lastTap.time < 450 && dx < 18 && dy < 18;

      lastTap = { time: now, x: p.x, y: p.y };

      if (mode === "touch" && event.pointerType !== "mouse") {
        send({ type: "touchEnd" });

        if (!wasDoubleTapArea) {
          send({ type: "tap", x: p.x, y: p.y });
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
        send({ type: "insertText", text: normalized });
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

    pauseBtn.onclick = () => {
      paused = !paused;
      pauseBtn.textContent = paused ? "Resume" : "Pause";
      pauseBtn.classList.toggle("active", paused);

      if (paused) {
        send({ type: "pauseRenderer" });
        setStatus("Renderer paused. Page continues loading in Chromium.", true);
      } else {
        send({ type: "resumeRenderer" });
        setStatus("Renderer resumed.", true);
      }
    };

    reconnectBtn.onclick = () => {
      setStatus("Reconnecting renderer...");
      connect();
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

npm install --no-package-lock

echo ""
echo "Starting stable renderer..."
echo "Open port 7860 again."
echo ""

PORT=7860 npm start
