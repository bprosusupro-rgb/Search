#!/usr/bin/env bash
set -e

echo "Patching touch support for Real Chromium renderer..."

if [ ! -f server.js ]; then
  echo "ERROR: server.js not found."
  exit 1
fi

if [ ! -f public/real.html ]; then
  echo "ERROR: public/real.html not found."
  exit 1
fi

cp server.js "server.js.backup-touch-$(date +%s)"
cp public/real.html "public/real.html.backup-touch-$(date +%s)"

node --input-type=commonjs <<'NODE'
const fs = require("fs");

const pkgPath = "package.json";
const serverPath = "server.js";

const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
pkg.dependencies = pkg.dependencies || {};
pkg.dependencies.ws = pkg.dependencies.ws || "^8.18.0";
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2));

let s = fs.readFileSync(serverPath, "utf8");

if (!s.includes('from "ws"')) {
  s = s.replace(
    /(import .*?;\n)/,
    `$1import { WebSocket } from "ws";\n`
  );
} else {
  s = s.replace(
    /import\s*\{\s*WebSocketServer\s*\}\s*from\s*"ws";/,
    `import { WebSocketServer, WebSocket } from "ws";`
  );
}

if (!s.includes("--touch-events=enabled")) {
  s = s.replace(
    /"--autoplay-policy=no-user-gesture-required",/,
    `"--autoplay-policy=no-user-gesture-required",
      "--touch-events=enabled",
      "--enable-pinch",
      "--overscroll-history-navigation=0",`
  );
}

if (!s.includes("/api/real/input")) {
  const touchBridge = `

/* ============================================================
   Touch bridge for iPad / touch devices
   Sends real Chrome DevTools Protocol touch events to Chromium.
   ============================================================ */

async function cdpPageForTouchBridge() {
  const targetsResponse = await fetch(\`http://127.0.0.1:\${CDP_PORT}/json/list\`);
  const targets = await targetsResponse.json();

  const page =
    targets.find((target) => target.type === "page" && target.webSocketDebuggerUrl) ||
    targets.find((target) => target.webSocketDebuggerUrl);

  if (!page) {
    throw new Error("No Chromium page found yet. Wait 2 seconds and try again.");
  }

  return page;
}

async function cdpCommandTouchBridge(method, params = {}) {
  const page = await cdpPageForTouchBridge();

  return await new Promise((resolve, reject) => {
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    const id = Math.floor(Math.random() * 1000000000);

    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error("Chrome touch bridge timed out."));
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

          if (msg.error) {
            reject(new Error(msg.error.message || "Chrome DevTools command failed."));
          } else {
            resolve(msg);
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

async function enableTouchBridge() {
  try {
    await cdpCommandTouchBridge("Emulation.setTouchEmulationEnabled", {
      enabled: true,
      maxTouchPoints: 5
    });
  } catch {}
}

app.get("/api/real/metrics", async (req, res) => {
  try {
    await enableTouchBridge();

    const result = await cdpCommandTouchBridge("Runtime.evaluate", {
      expression: "({ width: window.innerWidth, height: window.innerHeight, dpr: window.devicePixelRatio, scrollX: window.scrollX, scrollY: window.scrollY, href: location.href })",
      returnByValue: true
    });

    res.json({
      ok: true,
      metrics: result?.result?.result?.value || {
        width: 1500,
        height: 850,
        dpr: 1
      }
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

app.post("/api/real/input", async (req, res) => {
  try {
    await enableTouchBridge();

    const action = String(req.body?.action || "");
    const x = Number(req.body?.x || 0);
    const y = Number(req.body?.y || 0);
    const id = Number(req.body?.id || 1);

    if (action === "touch-start" || action === "touch-move") {
      await cdpCommandTouchBridge("Input.dispatchTouchEvent", {
        type: action === "touch-start" ? "touchStart" : "touchMove",
        touchPoints: [
          {
            x,
            y,
            id,
            radiusX: 4,
            radiusY: 4,
            force: 1
          }
        ]
      });

      return res.json({ ok: true });
    }

    if (action === "touch-end" || action === "touch-cancel") {
      await cdpCommandTouchBridge("Input.dispatchTouchEvent", {
        type: action === "touch-cancel" ? "touchCancel" : "touchEnd",
        touchPoints: []
      });

      return res.json({ ok: true });
    }

    if (action === "tap") {
      await cdpCommandTouchBridge("Input.dispatchTouchEvent", {
        type: "touchStart",
        touchPoints: [
          {
            x,
            y,
            id,
            radiusX: 4,
            radiusY: 4,
            force: 1
          }
        ]
      });

      await cdpCommandTouchBridge("Input.dispatchTouchEvent", {
        type: "touchEnd",
        touchPoints: []
      });

      return res.json({ ok: true });
    }

    if (action === "wheel") {
      const deltaX = Number(req.body?.deltaX || 0);
      const deltaY = Number(req.body?.deltaY || 0);

      await cdpCommandTouchBridge("Input.dispatchMouseEvent", {
        type: "mouseWheel",
        x,
        y,
        deltaX,
        deltaY,
        pointerType: "mouse"
      });

      return res.json({ ok: true });
    }

    res.status(400).json({
      ok: false,
      error: "Unknown input action."
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

`;

  if (s.includes('app.post("/api/real/navigate"')) {
    s = s.replace('app.post("/api/real/navigate"', touchBridge + '\napp.post("/api/real/navigate"');
  } else {
    s = s.replace(/server\.listen\(/, touchBridge + "\nserver.listen(");
  }
}

fs.writeFileSync(serverPath, s);
NODE

cat > public/real.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>Real Chromium Touch Renderer</title>

  <style>
    html,
    body,
    #screen {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #05070d;
      touch-action: none;
      overscroll-behavior: none;
    }

    #screen {
      position: absolute;
      inset: 0;
      z-index: 1;
    }

    #status {
      position: fixed;
      left: 14px;
      top: 14px;
      z-index: 30;
      padding: 10px 13px;
      border-radius: 999px;
      background: rgba(10, 14, 26, 0.88);
      color: white;
      font: 13px system-ui, sans-serif;
      border: 1px solid rgba(255,255,255,0.15);
      pointer-events: none;
    }

    #controls {
      position: fixed;
      right: 12px;
      top: 12px;
      z-index: 40;
      display: flex;
      gap: 8px;
      align-items: center;
      padding: 8px;
      border-radius: 18px;
      background: rgba(10, 14, 26, 0.72);
      border: 1px solid rgba(255,255,255,0.14);
      backdrop-filter: blur(14px);
    }

    button {
      border: 1px solid rgba(255,255,255,0.18);
      color: white;
      background: rgba(255,255,255,0.09);
      border-radius: 13px;
      padding: 9px 11px;
      font: 700 12px system-ui, sans-serif;
    }

    button.active {
      border: 0;
      background: linear-gradient(135deg, #7c5cff, #00d4ff);
    }

    #touchLayer {
      position: absolute;
      left: 0;
      right: 0;
      bottom: 0;
      z-index: 20;
      touch-action: none;
      overscroll-behavior: none;
      background: transparent;
    }

    #touchLayer.off {
      pointer-events: none;
    }

    #touchHint {
      position: fixed;
      left: 14px;
      bottom: 14px;
      z-index: 35;
      max-width: min(520px, calc(100vw - 28px));
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
  <div id="screen"></div>
  <div id="touchLayer"></div>

  <div id="status">Connecting to real Chromium...</div>

  <div id="controls">
    <button id="touchToggle" class="active">Touch ON</button>
    <button id="topMinus">Top −</button>
    <button id="topPlus">Top +</button>
  </div>

  <div id="touchHint">
    Touch mode: one finger = real page touch, two fingers = scroll. Use Top − / Top + if taps land slightly too high/low.
  </div>

  <script type="module">
    import RFB from "/novnc/core/rfb.js";

    const screen = document.getElementById("screen");
    const status = document.getElementById("status");
    const touchLayer = document.getElementById("touchLayer");
    const touchToggle = document.getElementById("touchToggle");
    const topMinus = document.getElementById("topMinus");
    const topPlus = document.getElementById("topPlus");

    let touchEnabled = true;
    let topOffset = 88;
    let metrics = {
      width: 1500,
      height: 850,
      dpr: 1
    };

    let lastMoveTime = 0;
    let activeTouch = false;
    let twoFingerScroll = false;
    let lastTwoFinger = null;

    function updateTouchLayer() {
      touchLayer.style.top = `${topOffset}px`;
      touchLayer.classList.toggle("off", !touchEnabled);
      touchToggle.classList.toggle("active", touchEnabled);
      touchToggle.textContent = touchEnabled ? "Touch ON" : "Touch OFF";
    }

    function setStatus(text, hide = false) {
      status.style.display = "block";
      status.textContent = text;

      if (hide) {
        clearTimeout(setStatus.timer);
        setStatus.timer = setTimeout(() => {
          status.style.display = "none";
        }, 1400);
      }
    }

    function clamp(value, min, max) {
      return Math.max(min, Math.min(max, value));
    }

    async function refreshMetrics() {
      try {
        const response = await fetch("/api/real/metrics", {
          cache: "no-store"
        });

        const data = await response.json();

        if (data.ok && data.metrics) {
          metrics = {
            width: Number(data.metrics.width || 1500),
            height: Number(data.metrics.height || 850),
            dpr: Number(data.metrics.dpr || 1)
          };
        }
      } catch {}
    }

    function pointFromTouch(touch) {
      const rect = touchLayer.getBoundingClientRect();

      const rx = clamp((touch.clientX - rect.left) / rect.width, 0, 1);
      const ry = clamp((touch.clientY - rect.top) / rect.height, 0, 1);

      return {
        x: Math.round(rx * metrics.width),
        y: Math.round(ry * metrics.height)
      };
    }

    function averageTouchPoint(touches) {
      let x = 0;
      let y = 0;

      for (const touch of touches) {
        x += touch.clientX;
        y += touch.clientY;
      }

      x /= touches.length;
      y /= touches.length;

      const fakeTouch = {
        clientX: x,
        clientY: y
      };

      return pointFromTouch(fakeTouch);
    }

    function averageClientPoint(touches) {
      let x = 0;
      let y = 0;

      for (const touch of touches) {
        x += touch.clientX;
        y += touch.clientY;
      }

      return {
        x: x / touches.length,
        y: y / touches.length
      };
    }

    async function sendInput(payload) {
      try {
        await fetch("/api/real/input", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "no-store"
          },
          body: JSON.stringify(payload)
        });
      } catch {}
    }

    async function connectVnc() {
      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const url = `${protocol}//${location.host}/websockify`;

      const rfb = new RFB(screen, url, {});
      rfb.scaleViewport = true;
      rfb.resizeSession = true;
      rfb.focusOnClick = true;
      rfb.viewOnly = false;
      rfb.showDotCursor = true;

      rfb.addEventListener("connect", () => {
        setStatus("Connected to real Chromium", true);
        refreshMetrics();
      });

      rfb.addEventListener("disconnect", () => {
        setStatus("Disconnected. Restart app if needed.");
      });

      rfb.addEventListener("credentialsrequired", () => {
        setStatus("VNC credentials required, but server should be passwordless.");
      });
    }

    touchToggle.addEventListener("click", () => {
      touchEnabled = !touchEnabled;
      updateTouchLayer();
    });

    topMinus.addEventListener("click", () => {
      topOffset = Math.max(40, topOffset - 8);
      updateTouchLayer();
      setStatus(`Touch top offset: ${topOffset}px`, true);
    });

    topPlus.addEventListener("click", () => {
      topOffset = Math.min(180, topOffset + 8);
      updateTouchLayer();
      setStatus(`Touch top offset: ${topOffset}px`, true);
    });

    touchLayer.addEventListener("touchstart", async (event) => {
      if (!touchEnabled) return;

      event.preventDefault();
      await refreshMetrics();

      if (event.touches.length >= 2) {
        twoFingerScroll = true;
        lastTwoFinger = averageClientPoint(event.touches);
        activeTouch = false;
        return;
      }

      twoFingerScroll = false;
      activeTouch = true;

      const p = pointFromTouch(event.touches[0]);

      await sendInput({
        action: "touch-start",
        id: 1,
        x: p.x,
        y: p.y
      });
    }, { passive: false });

    touchLayer.addEventListener("touchmove", async (event) => {
      if (!touchEnabled) return;

      event.preventDefault();

      const now = performance.now();
      if (now - lastMoveTime < 16) return;
      lastMoveTime = now;

      if (event.touches.length >= 2) {
        const current = averageClientPoint(event.touches);
        const p = averageTouchPoint(event.touches);

        if (lastTwoFinger) {
          const dx = current.x - lastTwoFinger.x;
          const dy = current.y - lastTwoFinger.y;

          await sendInput({
            action: "wheel",
            x: p.x,
            y: p.y,
            deltaX: -dx * 2.8,
            deltaY: -dy * 2.8
          });
        }

        lastTwoFinger = current;
        return;
      }

      if (!activeTouch || twoFingerScroll) return;

      const p = pointFromTouch(event.touches[0]);

      await sendInput({
        action: "touch-move",
        id: 1,
        x: p.x,
        y: p.y
      });
    }, { passive: false });

    touchLayer.addEventListener("touchend", async (event) => {
      if (!touchEnabled) return;

      event.preventDefault();

      if (twoFingerScroll) {
        if (event.touches.length === 0) {
          twoFingerScroll = false;
          lastTwoFinger = null;
        }
        return;
      }

      if (activeTouch) {
        activeTouch = false;

        await sendInput({
          action: "touch-end",
          id: 1
        });
      }
    }, { passive: false });

    touchLayer.addEventListener("touchcancel", async (event) => {
      if (!touchEnabled) return;

      event.preventDefault();

      activeTouch = false;
      twoFingerScroll = false;
      lastTwoFinger = null;

      await sendInput({
        action: "touch-cancel",
        id: 1
      });
    }, { passive: false });

    updateTouchLayer();
    connectVnc();
    refreshMetrics();
    setInterval(refreshMetrics, 2500);
  </script>
</body>
</html>
EOF

echo "Installing updated package dependencies..."
npm install --no-package-lock

echo ""
echo "Restarting app..."
pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
pkill -f "x11vnc" 2>/dev/null || true
sleep 1

echo ""
echo "Open port 7860 again."
echo "Use Real mode. Touch ON should appear in the top-right of the renderer."
echo ""

PORT=7860 npm start
