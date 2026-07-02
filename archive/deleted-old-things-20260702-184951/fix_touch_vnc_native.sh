#!/usr/bin/env bash
set -e

echo "Replacing broken touch bridge with native noVNC touch support..."

pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
pkill -f "x11vnc" 2>/dev/null || true
sleep 1

if [ ! -f public/real.html ]; then
  echo "ERROR: public/real.html not found."
  exit 1
fi

cp public/real.html "public/real.html.backup-broken-touch-$(date +%s)"

cat > public/real.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>Real Chromium Renderer</title>

  <style>
    html,
    body,
    #screen {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #05070d;
      overscroll-behavior: none;
    }

    body {
      position: fixed;
      inset: 0;
      touch-action: none;
    }

    #screen {
      position: absolute;
      inset: 0;
      z-index: 1;
      touch-action: none;
      overscroll-behavior: none;
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
      font: 800 12px system-ui, sans-serif;
    }

    button.active {
      border: 0;
      background: linear-gradient(135deg, #7c5cff, #00d4ff);
    }

    #hint {
      position: fixed;
      left: 14px;
      bottom: 14px;
      z-index: 35;
      max-width: min(580px, calc(100vw - 28px));
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

  <div id="status">Connecting to real Chromium...</div>

  <div id="controls">
    <button id="leftClickBtn" class="active">Left click</button>
    <button id="middleClickBtn">Middle</button>
    <button id="rightClickBtn">Right</button>
    <button id="keyboardBtn">Keyboard</button>
  </div>

  <div id="hint">
    Native touch mode: tap = click, drag = drag/select, two-finger scroll should work. For typing, tap a field, then use Keyboard.
  </div>

  <script type="module">
    import RFB from "/novnc/core/rfb.js";

    const screen = document.getElementById("screen");
    const status = document.getElementById("status");
    const leftClickBtn = document.getElementById("leftClickBtn");
    const middleClickBtn = document.getElementById("middleClickBtn");
    const rightClickBtn = document.getElementById("rightClickBtn");
    const keyboardBtn = document.getElementById("keyboardBtn");

    let rfb = null;

    function setStatus(text, hide = false) {
      status.style.display = "block";
      status.textContent = text;

      if (hide) {
        clearTimeout(setStatus.timer);
        setStatus.timer = setTimeout(() => {
          status.style.display = "none";
        }, 1500);
      }
    }

    function activateButton(btn) {
      leftClickBtn.classList.remove("active");
      middleClickBtn.classList.remove("active");
      rightClickBtn.classList.remove("active");
      btn.classList.add("active");
    }

    function setMouseButton(buttonNumber) {
      if (!rfb) return;

      try {
        rfb.touchButton = buttonNumber;
      } catch {}

      if (buttonNumber === 1) activateButton(leftClickBtn);
      if (buttonNumber === 2) activateButton(middleClickBtn);
      if (buttonNumber === 4) activateButton(rightClickBtn);
    }

    async function openKeyboard() {
      const input = document.createElement("input");
      input.style.position = "fixed";
      input.style.left = "0";
      input.style.bottom = "0";
      input.style.width = "1px";
      input.style.height = "1px";
      input.style.opacity = "0";
      input.autocapitalize = "off";
      input.autocomplete = "off";
      input.autocorrect = "off";
      input.spellcheck = false;

      document.body.appendChild(input);
      input.focus();

      setStatus("Keyboard opened. Type normally after focusing a field.", true);

      setTimeout(() => {
        input.remove();
      }, 10000);
    }

    function installTouchGuards() {
      document.addEventListener("gesturestart", (e) => e.preventDefault(), { passive: false });
      document.addEventListener("gesturechange", (e) => e.preventDefault(), { passive: false });
      document.addEventListener("gestureend", (e) => e.preventDefault(), { passive: false });

      document.addEventListener("touchmove", (e) => {
        if (e.target.closest("#controls")) return;
        e.preventDefault();
      }, { passive: false });

      document.addEventListener("contextmenu", (e) => {
        e.preventDefault();
      });
    }

    function connect() {
      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const url = `${protocol}//${location.host}/websockify`;

      rfb = new RFB(screen, url, {
        shared: true,
        repeaterID: "",
        credentials: {}
      });

      rfb.scaleViewport = true;
      rfb.resizeSession = true;
      rfb.focusOnClick = true;
      rfb.viewOnly = false;
      rfb.clipViewport = false;
      rfb.dragViewport = false;
      rfb.showDotCursor = true;
      rfb.qualityLevel = 6;
      rfb.compressionLevel = 2;

      try {
        rfb.touchButton = 1;
      } catch {}

      rfb.addEventListener("connect", () => {
        setStatus("Connected. Native touch mode active.", true);
        setMouseButton(1);
      });

      rfb.addEventListener("disconnect", () => {
        setStatus("Disconnected. Restart app if needed.");
      });

      rfb.addEventListener("credentialsrequired", () => {
        setStatus("VNC credentials required, but server should be passwordless.");
      });
    }

    leftClickBtn.addEventListener("click", () => setMouseButton(1));
    middleClickBtn.addEventListener("click", () => setMouseButton(2));
    rightClickBtn.addEventListener("click", () => setMouseButton(4));
    keyboardBtn.addEventListener("click", openKeyboard);

    installTouchGuards();
    connect();
  </script>
</body>
</html>
EOF

echo ""
echo "Restarting app..."
npm install --no-package-lock

echo ""
echo "Open port 7860 again."
echo "Use Real mode."
echo ""

PORT=7860 npm start
