#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "===================================================="
echo " Fix start.sh: install/check all browser dependencies"
echo "===================================================="
echo ""

STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="archive/start-fix-$STAMP"
mkdir -p "$ARCHIVE"

[ -f start.sh ] && cp -a start.sh "$ARCHIVE/start.sh.backup"
[ -f install_browser_deps.sh ] && cp -a install_browser_deps.sh "$ARCHIVE/install_browser_deps.sh.backup"

cat > install_browser_deps.sh <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo ""
echo "===================================================="
echo " Installing browser system dependencies"
echo "===================================================="
echo ""

if ! command -v sudo >/dev/null 2>&1; then
  echo "ERROR: sudo not found. This install script needs sudo in Codespaces/devcontainer."
  exit 1
fi

sudo apt-get update

sudo apt-get install -y --no-install-recommends \
  chromium \
  xvfb \
  x11vnc \
  fluxbox \
  novnc \
  websockify \
  dbus-x11 \
  ca-certificates \
  fonts-liberation \
  fonts-noto-color-emoji \
  xdg-utils \
  curl \
  procps \
  iproute2

sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

echo ""
echo "Installed versions / paths:"
echo "Chromium: $(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
echo "Xvfb:     $(command -v Xvfb || true)"
echo "x11vnc:   $(command -v x11vnc || true)"
echo "fluxbox:  $(command -v fluxbox || true)"
echo "noVNC:    $([ -d /usr/share/novnc ] && echo /usr/share/novnc || echo missing)"
echo ""
echo "Done."
INSTALL

chmod +x install_browser_deps.sh

cat > start.sh <<'START'
#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-7860}"
WATCH_PORT="${WATCH_PORT:-7861}"
SCREEN_SIZE="${SCREEN_SIZE:-1280x720x24}"
CHROME_WINDOW_SIZE="${CHROME_WINDOW_SIZE:-1280,720}"
NOVNC_QUALITY="${NOVNC_QUALITY:-7}"
NOVNC_COMPRESSION="${NOVNC_COMPRESSION:-2}"
VNC_WAIT_MS="${VNC_WAIT_MS:-10}"
VNC_DEFER_MS="${VNC_DEFER_MS:-10}"

echo ""
echo "===================================================="
echo " Starting Real noVNC Chromium Browser"
echo "===================================================="
echo "Main Port:          $PORT"
echo "Watch Port:         $WATCH_PORT"
echo "Screen Size:        $SCREEN_SIZE"
echo "Chrome Window Size: $CHROME_WINDOW_SIZE"
echo "noVNC Quality:      $NOVNC_QUALITY"
echo "noVNC Compression:  $NOVNC_COMPRESSION"
echo "===================================================="
echo ""

need_install=0

has_chromium() {
  command -v chromium >/dev/null 2>&1 || \
  command -v chromium-browser >/dev/null 2>&1 || \
  command -v google-chrome >/dev/null 2>&1 || \
  command -v google-chrome-stable >/dev/null 2>&1
}

check_cmd() {
  local name="$1"
  local cmd="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing: $name ($cmd)"
    need_install=1
  else
    echo "OK: $name -> $(command -v "$cmd")"
  fi
}

echo "[1/8] Checking system dependencies..."

if ! has_chromium; then
  echo "Missing: Chromium browser"
  need_install=1
else
  echo "OK: Chromium -> $(command -v chromium || command -v chromium-browser || command -v google-chrome || command -v google-chrome-stable)"
fi

check_cmd "Xvfb" "Xvfb"
check_cmd "x11vnc" "x11vnc"
check_cmd "fluxbox" "fluxbox"
check_cmd "curl" "curl"

if [ ! -d "/usr/share/novnc" ]; then
  echo "Missing: /usr/share/novnc"
  need_install=1
else
  echo "OK: noVNC -> /usr/share/novnc"
fi

if [ "$need_install" = "1" ]; then
  echo ""
  echo "[2/8] Missing dependencies found. Installing now..."
  if [ ! -f "./install_browser_deps.sh" ]; then
    echo "ERROR: install_browser_deps.sh not found."
    exit 1
  fi
  ./install_browser_deps.sh
else
  echo ""
  echo "[2/8] All system dependencies already installed."
fi

echo ""
echo "[3/8] Checking project files..."

if [ ! -f "server.js" ]; then
  echo "ERROR: server.js not found. Run this from the repo root."
  exit 1
fi

if [ ! -f "package.json" ]; then
  echo "ERROR: package.json not found. Run this from the repo root."
  exit 1
fi

if [ ! -d "public" ]; then
  echo "ERROR: public folder not found."
  exit 1
fi

echo ""
echo "[4/8] Installing npm dependencies..."
npm install --no-package-lock

echo ""
echo "[5/8] Syntax check..."
node --check server.js
node -e "JSON.parse(require('fs').readFileSync('package.json','utf8')); console.log('package.json OK')"

echo ""
echo "[6/8] Clearing old runtime logs..."
mkdir -p logs
: > logs/start.log
: > logs/runtime.log

echo ""
echo "[7/8] Stopping old browser processes..."
pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "chromium-browser" 2>/dev/null || true
pkill -f "google-chrome" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
pkill -f "x11vnc" 2>/dev/null || true
pkill -f "fluxbox" 2>/dev/null || true
pkill -f "websockify" 2>/dev/null || true
sleep 1

echo ""
echo "[8/8] Open these links in Codespaces:"
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  echo ""
  echo "Main:"
  echo "https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/"
  echo ""
  echo "Doctor:"
  echo "https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/doctor.html"
  echo ""
  echo "Watch:"
  echo "https://${CODESPACE_NAME}-${WATCH_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/watch.html?quality=${NOVNC_QUALITY}&compression=${NOVNC_COMPRESSION}"
else
  echo ""
  echo "Main:"
  echo "http://127.0.0.1:${PORT}/"
  echo ""
  echo "Doctor:"
  echo "http://127.0.0.1:${PORT}/doctor.html"
  echo ""
  echo "Watch:"
  echo "http://127.0.0.1:${WATCH_PORT}/watch.html?quality=${NOVNC_QUALITY}&compression=${NOVNC_COMPRESSION}"
fi

echo ""
echo "Browser is starting..."
echo "Press Ctrl+C here to stop it."
echo ""

PORT="$PORT" \
WATCH_PORT="$WATCH_PORT" \
SCREEN_SIZE="$SCREEN_SIZE" \
CHROME_WINDOW_SIZE="$CHROME_WINDOW_SIZE" \
NOVNC_QUALITY="$NOVNC_QUALITY" \
NOVNC_COMPRESSION="$NOVNC_COMPRESSION" \
VNC_WAIT_MS="$VNC_WAIT_MS" \
VNC_DEFER_MS="$VNC_DEFER_MS" \
npm start 2>&1 | tee -a logs/runtime.log
START

chmod +x start.sh

echo ""
echo "Final check:"
bash -n start.sh
bash -n install_browser_deps.sh

echo ""
echo "===================================================="
echo "Done."
echo "Backup saved in: $ARCHIVE"
echo "===================================================="
echo ""
echo "Now run:"
echo "  ./start.sh"
echo ""
