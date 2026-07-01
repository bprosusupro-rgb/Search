#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

export HISTFILE=/dev/null
export PYTHONHISTFILE=/dev/null
set +o history 2>/dev/null || true

PORT="${PORT:-7860}"
DISPLAY_NUM="${DISPLAY_NUM:-:99}"
VNC_PORT="${VNC_PORT:-5900}"
SCREEN_SIZE="${SCREEN_SIZE:-1600x1000}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

find_chromium() {
  if need_cmd chromium; then
    echo "chromium"
  elif need_cmd chromium-browser; then
    echo "chromium-browser"
  elif need_cmd google-chrome; then
    echo "google-chrome"
  elif need_cmd google-chrome-stable; then
    echo "google-chrome-stable"
  else
    echo ""
  fi
}

CHROME_BIN="$(find_chromium)"

if ! need_cmd Xvfb || ! need_cmd x11vnc || ! need_cmd websockify || [ -z "$CHROME_BIN" ]; then
  echo "Missing browser dependencies. Installing them now..."
  bash ./install_browser_deps.sh
  CHROME_BIN="$(find_chromium)"
fi

if [ -z "$CHROME_BIN" ]; then
  echo "ERROR: Chromium could not be found after installation."
  exit 1
fi

TEMP_ROOT="$(mktemp -d)"
PROFILE_DIR="$TEMP_ROOT/chromium-profile"
CACHE_DIR="$TEMP_ROOT/chromium-cache"
MEDIA_CACHE_DIR="$TEMP_ROOT/chromium-media-cache"
HOME_DIR="$TEMP_ROOT/home"
RUNTIME_DIR="$TEMP_ROOT/runtime"
VNC_PASS_FILE="$TEMP_ROOT/vnc.pass"

mkdir -p "$PROFILE_DIR/Default" "$CACHE_DIR" "$MEDIA_CACHE_DIR" "$HOME_DIR" "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

export HOME="$HOME_DIR"
export XDG_CACHE_HOME="$TEMP_ROOT/xdg-cache"
export XDG_CONFIG_HOME="$TEMP_ROOT/xdg-config"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export DISPLAY="$DISPLAY_NUM"

PIDS=()

cleanup() {
  echo ""
  echo "Stopping browser and deleting temporary profile..."

  for pid in "${PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done

  wait >/dev/null 2>&1 || true
  rm -rf "$TEMP_ROOT"
  history -c 2>/dev/null || true

  echo "Cleaned."
}

trap cleanup EXIT INT TERM

VNC_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)"

x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASS_FILE" >/dev/null 2>&1

cat > "$PROFILE_DIR/Default/Preferences" <<'PREFS'
{
  "browser": {
    "check_default_browser": false,
    "has_seen_welcome_page": true
  },
  "credentials_enable_service": false,
  "profile": {
    "password_manager_enabled": false
  },
  "default_search_provider": {
    "enabled": true,
    "name": "DuckDuckGo",
    "keyword": "duckduckgo.com",
    "search_url": "https://duckduckgo.com/?q={searchTerms}",
    "suggest_url": "https://duckduckgo.com/ac/?q={searchTerms}&type=list"
  }
}
PREFS

HOME_PAGE="file://$(realpath ./public/home.html)"

echo ""
echo "Starting virtual display..."
Xvfb "$DISPLAY_NUM" -screen 0 "${SCREEN_SIZE}x24" -ac +extension RANDR >/dev/null 2>&1 &
PIDS+=("$!")
sleep 1

echo "Starting window manager..."
fluxbox >/dev/null 2>&1 &
PIDS+=("$!")
sleep 1

echo "Starting VNC server..."
x11vnc \
  -display "$DISPLAY_NUM" \
  -localhost \
  -forever \
  -shared \
  -rfbauth "$VNC_PASS_FILE" \
  -rfbport "$VNC_PORT" \
  -quiet \
  >/dev/null 2>&1 &
PIDS+=("$!")
sleep 1

NOVNC_WEB="/usr/share/novnc"
if [ ! -d "$NOVNC_WEB" ]; then
  echo "ERROR: noVNC web folder not found at $NOVNC_WEB"
  exit 1
fi

echo "Starting noVNC on port $PORT..."
websockify \
  --web="$NOVNC_WEB" \
  "0.0.0.0:$PORT" \
  "localhost:$VNC_PORT" \
  >/dev/null 2>&1 &
PIDS+=("$!")
sleep 1

echo "Starting Chromium..."
"$CHROME_BIN" \
  --user-data-dir="$PROFILE_DIR" \
  --disk-cache-dir="$CACHE_DIR" \
  --media-cache-dir="$MEDIA_CACHE_DIR" \
  --incognito \
  --no-first-run \
  --no-default-browser-check \
  --disable-sync \
  --disable-logging \
  --disable-breakpad \
  --disable-crash-reporter \
  --disable-background-networking \
  --disable-component-update \
  --disable-features=AutofillServerCommunication,MediaRouter,OptimizationHints \
  --disable-dev-shm-usage \
  --password-store=basic \
  --use-mock-keychain \
  --force-dark-mode \
  --enable-features=WebUIDarkMode \
  --start-maximized \
  --window-size=1500,950 \
  --no-sandbox \
  "$HOME_PAGE" \
  >/dev/null 2>&1 &
CHROME_PID="$!"
PIDS+=("$CHROME_PID")

echo ""
echo "============================================================"
echo " Real Chromium Browser is running"
echo ""
echo " Open Codespaces forwarded port: $PORT"
echo ""
echo " If it does not auto-open, open:"
echo " /vnc.html?autoconnect=1&resize=scale"
echo ""
echo " VNC password:"
echo " $VNC_PASSWORD"
echo ""
echo " Keep the Codespaces port PRIVATE."
echo " Browser profile/cache are temporary and deleted on stop."
echo "============================================================"
echo ""

while kill -0 "$CHROME_PID" >/dev/null 2>&1; do
  sleep 2
done
