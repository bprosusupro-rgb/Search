#!/usr/bin/env bash
set -e

PORT="${PORT:-7860}"

echo ""
echo "===================================================="
echo " Starting Real noVNC Chromium Browser"
echo " Port: $PORT"
echo "===================================================="
echo ""

echo "Stopping old browser processes..."
pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
pkill -f "x11vnc" 2>/dev/null || true
pkill -f "websockify" 2>/dev/null || true
sleep 1

if [ ! -f "server.js" ]; then
  echo "ERROR: server.js not found."
  echo "Run the browser install command first."
  exit 1
fi

if [ ! -f "package.json" ]; then
  echo "ERROR: package.json not found."
  echo "Run the browser install command first."
  exit 1
fi

if [ ! -d "node_modules" ]; then
  echo "Installing npm packages..."
  npm install --no-package-lock
fi

echo ""
echo "Open this port in Codespaces:"
echo "$PORT"

if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  echo ""
  echo "Correct link:"
  echo "https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/"
fi

echo ""
echo "Browser is starting..."
echo "Press Ctrl+C here to stop it."
echo ""

PORT="$PORT" npm start
