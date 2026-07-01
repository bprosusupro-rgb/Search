#!/usr/bin/env bash
set -e

echo "Installing YouTube-style touch controller..."

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

cp server.js "server.js.backup-youtube-touch-$(date +%s)"
cp public/real.html "public/real.html.backup-youtube-touch-$(date +%s)"

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let s = fs.readFileSync("server.js", "utf8");

if (!s.includes('msg.type === "youtubeAction"')) {
  const youtubeActionBlock = `
      if (msg.type === "youtubeAction") {
        const ytAction = String(msg.action || "");
        const ytSeconds = Number(msg.seconds || 0);

        const expr =
          "(() => {" +
          "  const action = " + JSON.stringify(ytAction) + ";" +
          "  const seconds = " + JSON.stringify(Number.isFinite(ytSeconds) ? ytSeconds : 0) + ";" +
          "  const host = String(location.hostname || '').toLowerCase();" +
          "  const isYouTube = host === 'youtube.com' || host.endsWith('.youtube.com') || host === 'youtu.be' || host.endsWith('.youtu.be');" +
          "  const video = document.querySelector('video');" +
          "  if (!isYouTube || !video) return { ok: false, reason: 'Not on YouTube video page.' };" +
          "  if (action === 'seek') {" +
          "    const duration = Number.isFinite(video.duration) ? video.duration : 999999;" +
          "    video.currentTime = Math.max(0, Math.min(duration, video.currentTime + seconds));" +
          "    return { ok: true, action, seconds, currentTime: video.currentTime };" +
          "  }" +
          "  if (action === 'togglePlay') {" +
          "    if (video.paused) { video.play(); return { ok: true, action, playing: true }; }" +
          "    video.pause(); return { ok: true, action, playing: false };" +
          "  }" +
          "  if (action === 'speedStart') {" +
          "    if (!window.__codespaceOldPlaybackRate) window.__codespaceOldPlaybackRate = video.playbackRate || 1;" +
          "    video.playbackRate = 2;" +
          "    return { ok: true, action, playbackRate: video.playbackRate };" +
          "  }" +
          "  if (action === 'speedEnd') {" +
          "    video.playbackRate = window.__codespaceOldPlaybackRate || 1;" +
          "    window.__codespaceOldPlaybackRate = null;" +
          "    return { ok: true, action, playbackRate: video.playbackRate };" +
          "  }" +
          "  if (action === 'mute') {" +
          "    video.muted = !video.muted;" +
          "    return { ok: true, action, muted: video.muted };" +
          "  }" +
          "  return { ok: false, reason: 'Unknown YouTube action.' };" +
          "})()";

        const result = await sendChrome("Runtime.evaluate", {
          expression: expr,
          returnByValue: true,
          awaitPromise: true
        });

        const value = result?.result?.value || {};
        sendClient({
          type: "youtubeActionResult",
          action: ytAction,
          ...value
        });

        return;
      }

`;

  const needle = `if (msg.type === "insertText") {`;

  if (!s.includes(needle)) {
    console.error("Could not find insertText handler in server.js. Your server.js is not the expected CDP version.");
    process.exit(1);
  }

  s = s.replace(needle, youtubeActionBlock + `      ` + needle);
}

if (!s.includes("--touch-events=enabled")) {
  s = s.replace(
    `"--autoplay-policy=no-user-gesture-required",`,
    `"--autoplay-policy=no-user-gesture-required",
      "--touch-events=enabled",
      "--enable-pinch",
      "--overscroll-history-navigation=0",`
  );
}

fs.writeFileSync("server.js", s);
NODE

cat > public/real.html <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>YouTube Touch CDP Renderer</title>
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
      max-width: min(760px, calc(100vw - 28px));
      padding: 10px 12px;
      border-radius: 16px;
      background: rgba(10, 14, 26, 0.74);
      color: rgba(255,255,255,0.78);
      font: 12px/1.4 system-ui, sans-serif;
      border: 1px solid rgba(255,255,255,0.12);
      backdrop-filter: blur(14px);
      pointer-events: none;
    }

    #gestureOverlay {
      position: fixed;
      inset: 0;
      z-index: 24;
      display: none;
      place-items: center;
      pointer-events: none;
      font: 900 clamp(32px, 8vw, 78px) system-ui, sans-serif;
      color: white;
      text-shadow: 0 8px 40px rgba(0,0,0,.8);
    }

    #gestureOverlay.visible {
      display: grid;
      animation: gesture-pop 520ms ease both;
    }

    #gestureOverlay.left {
      place-items: center start;
      padding-left: 16%;
    }

    #gestureOverlay.right {
      place-items: center end;
      padding-right: 16%;
    }

    @keyframes gesture-pop {
      0% { opacity: 0; transform: scale(.86); }
      15% { opacity: 1; transform: scale(1); }
      100% { opacity: 0; transform: scale(1.08); }
    }
  </style>
</head>

<body>
  <canvas id="canvas"></canvas>

  <div id="status">Connecting to Chromium...</div>

  <div id="toolbar">
    <button id="touchBtn" class="active">YT Touch</button>
    <button id="mouseBtn">Mouse</button>
    <button id="keyboardBtn">Keyboard</button>
    <button id="backspaceBtn">⌫</button>
    <button id="enterBtn">Enter</button>
    <button id="reloadBtn">↻</button>
    <button id="pauseBtn">Pause</button>
    <button id="reconnectBtn">Reconnect</button>
  </div>

  <input id="keyboardBox" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" />

  <div id="gestureOverlay"></div>

  <div id="hint">
    YouTube touch mode: tap = click, double tap left/right = ±10s, double tap middle = play/pause, hold = 2× speed, drag = scroll.
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
    const gestureOverlay = document.getElementById("gestureOverlay");

    let ws;
    let mode = "youtube-touch";
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
    let primaryGesture = null;
    let lastTwoFinger = null;
    let lastTapInfo = null;
    let singleTapTimer = null;
    let longPressTimer = null;
    let longPressActive = false;
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

    function showGesture(text, side = "center") {
      gestureOverlay.className = "";
      gestureOverlay.textContent = text;

      if (side === "left") gestureOverlay.classList.add("left");
      if (side === "right") gestureOverlay.classList.add("right");

      void gestureOverlay.offsetWidth;
      gestureOverlay.classList.add("visible");

      clearTimeout(showGesture.timer);
      showGesture.timer = setTimeout(() => {
        gestureOverlay.classList.remove("visible");
      }, 560);
    }

    function send(obj) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(obj));
      }
    }

    function youtubeAction(action, seconds = 0) {
      send({
        type: "youtubeAction",
        action,
        seconds
      });
    }

    function connect() {
      if (ws) {
        try { ws.close(); } catch {}
      }

      setStatus("Connecting...");

      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      ws = new WebSocket(`${protocol}//${location.host}/cdp-renderer`);

      ws.onopen = () => {
        setStatus("Connected. YouTube touch controller active.", true);
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

        if (msg.type === "youtubeActionResult") {
          if (!msg.ok && msg.reason) {
            setStatus(msg.reason, true);
          }
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
          setStatus(`Stable renderer active. Dropped ${msg.droppedFrames} old frames.`, true);
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

    function remoteFromClientPoint(clientX, clientY) {
      const rect = canvas.getBoundingClientRect();

      const rx = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
      const ry = Math.max(0, Math.min(1, (clientY - rect.top) / rect.height));

      return {
        x: Math.round(rx * (lastFrameMeta.deviceWidth || 1280)),
        y: Math.round(ry * (lastFrameMeta.deviceHeight || 760)),
        rx,
        ry
      };
    }

    function pointFromEvent(event) {
      const p = remoteFromClientPoint(event.clientX, event.clientY);

      return {
        id: event.pointerId || 1,
        x: p.x,
        y: p.y,
        rx: p.rx,
        ry: p.ry,
        clientX: event.clientX,
        clientY: event.clientY
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

    function tapZone(point) {
      if (point.rx < 0.35) return "left";
      if (point.rx > 0.65) return "right";
      return "center";
    }

    function clearLongPress() {
      clearTimeout(longPressTimer);
      longPressTimer = null;
    }

    function clearSingleTapTimer() {
      clearTimeout(singleTapTimer);
      singleTapTimer = null;
    }

    function sendNormalTap(point) {
      send({
        type: "tap",
        x: point.x,
        y: point.y
      });
    }

    function handleDoubleTap(point) {
      const zone = tapZone(point);

      if (zone === "left") {
        youtubeAction("seek", -10);
        showGesture("⟲ 10", "left");
        return;
      }

      if (zone === "right") {
        youtubeAction("seek", 10);
        showGesture("10 ⟳", "right");
        return;
      }

      youtubeAction("togglePlay", 0);
      showGesture("▶︎ / ❚❚", "center");
    }

    function startLongPressWatch(point) {
      clearLongPress();

      longPressTimer = setTimeout(() => {
        if (!primaryGesture) return;
        if (primaryGesture.moved) return;
        if (activePointers.size !== 1) return;

        longPressActive = true;
        youtubeAction("speedStart", 0);
        showGesture("2×", "center");
      }, 520);
    }

    function finishLongPress() {
      if (!longPressActive) return;

      longPressActive = false;
      youtubeAction("speedEnd", 0);
      showGesture("1×", "center");
    }

    canvas.addEventListener("pointerdown", (event) => {
      event.preventDefault();

      if (event.target.closest && event.target.closest("#toolbar")) return;

      try {
        canvas.setPointerCapture(event.pointerId);
      } catch {}

      const p = pointFromEvent(event);

      activePointers.set(event.pointerId, p);

      if (activePointers.size >= 2) {
        clearLongPress();
        finishLongPress();
        clearSingleTapTimer();
        lastTwoFinger = averageClient(Array.from(activePointers.values()));
        return;
      }

      primaryGesture = {
        id: event.pointerId,
        start: p,
        last: p,
        startTime: performance.now(),
        moved: false,
        gestureType: "pending"
      };

      if (mode === "mouse" || event.pointerType === "mouse") {
        return;
      }

      startLongPressWatch(p);
    }, { passive: false });

    canvas.addEventListener("pointermove", (event) => {
      event.preventDefault();

      if (!activePointers.has(event.pointerId)) return;

      const p = pointFromEvent(event);
      activePointers.set(event.pointerId, p);

      const all = Array.from(activePointers.values());

      if (all.length >= 2) {
        clearLongPress();
        finishLongPress();

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

      if (!primaryGesture || primaryGesture.id !== event.pointerId) return;

      const dx = p.clientX - primaryGesture.start.clientX;
      const dy = p.clientY - primaryGesture.start.clientY;
      const absX = Math.abs(dx);
      const absY = Math.abs(dy);

      if (absX > 8 || absY > 8) {
        primaryGesture.moved = true;
        clearLongPress();
      }

      if (primaryGesture.gestureType === "pending" && (absX > 12 || absY > 12)) {
        if (absY > absX * 1.15) {
          primaryGesture.gestureType = "scroll";
        } else {
          primaryGesture.gestureType = "drag";
          send({
            type: "touchStart",
            points: [
              {
                id: 1,
                x: primaryGesture.start.x,
                y: primaryGesture.start.y
              }
            ]
          });
        }
      }

      if (primaryGesture.gestureType === "scroll") {
        const last = primaryGesture.last;

        send({
          type: "wheel",
          x: p.x,
          y: p.y,
          deltaX: -(p.clientX - last.clientX) * 1.6,
          deltaY: -(p.clientY - last.clientY) * 2.4
        });
      }

      if (primaryGesture.gestureType === "drag") {
        send({
          type: "touchMove",
          points: [
            {
              id: 1,
              x: p.x,
              y: p.y
            }
          ]
        });
      }

      primaryGesture.last = p;
    }, { passive: false });

    canvas.addEventListener("pointerup", (event) => {
      event.preventDefault();

      const p = pointFromEvent(event);

      activePointers.delete(event.pointerId);

      if (activePointers.size === 0) {
        lastTwoFinger = null;
      }

      clearLongPress();

      if (longPressActive) {
        finishLongPress();
        primaryGesture = null;
        return;
      }

      if (mode === "mouse" || event.pointerType === "mouse") {
        sendNormalTap(p);
        primaryGesture = null;
        return;
      }

      if (primaryGesture && primaryGesture.gestureType === "drag") {
        send({ type: "touchEnd" });
        primaryGesture = null;
        return;
      }

      const now = performance.now();
      const zone = tapZone(p);
      const moved = primaryGesture?.moved || false;

      primaryGesture = null;

      if (moved) {
        return;
      }

      if (
        lastTapInfo &&
        now - lastTapInfo.time < 360 &&
        lastTapInfo.zone === zone &&
        Math.abs(p.clientX - lastTapInfo.clientX) < 90 &&
        Math.abs(p.clientY - lastTapInfo.clientY) < 90
      ) {
        clearSingleTapTimer();
        handleDoubleTap(p);
        lastTapInfo = null;
        return;
      }

      lastTapInfo = {
        time: now,
        zone,
        clientX: p.clientX,
        clientY: p.clientY
      };

      clearSingleTapTimer();

      singleTapTimer = setTimeout(() => {
        sendNormalTap(p);
        singleTapTimer = null;
      }, 240);
    }, { passive: false });

    canvas.addEventListener("pointercancel", (event) => {
      event.preventDefault();

      clearLongPress();
      finishLongPress();
      clearSingleTapTimer();

      activePointers.clear();
      primaryGesture = null;
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
        setStatus("Keyboard open. Tap a field first, then type here.", true);
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
      mode = "youtube-touch";
      touchBtn.classList.add("active");
      mouseBtn.classList.remove("active");
      setStatus("YouTube-style touch mode active.", true);
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
echo "Starting YouTube-style touch browser..."
echo "Open port 7860 again."
echo ""

PORT=7860 npm start
