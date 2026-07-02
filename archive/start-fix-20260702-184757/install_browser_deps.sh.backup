#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

echo "Installing real browser dependencies..."

sudo apt-get update

sudo apt-get install -y --no-install-recommends \
  chromium \
  xvfb \
  fluxbox \
  x11vnc \
  novnc \
  websockify \
  dbus-x11 \
  ca-certificates \
  fonts-liberation \
  fonts-noto-color-emoji \
  xdg-utils

sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

echo "Done."
