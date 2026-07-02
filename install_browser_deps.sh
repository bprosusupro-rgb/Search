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
