#!/usr/bin/env bash

# Do not save shell history for this session
export HISTFILE=/dev/null
export PYTHONHISTFILE=/dev/null
set +o history 2>/dev/null || true

# Temporary cache only
PRIVATE_TEMP="$(mktemp -d)"
export XDG_CACHE_HOME="$PRIVATE_TEMP"
export PIP_CACHE_DIR="$PRIVATE_TEMP/pip-cache"

cleanup() {
  rm -rf "$PRIVATE_TEMP"
  history -c 2>/dev/null || true
}

trap cleanup EXIT

python3 search_web.py
