#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "===================================================="
echo " Delete old / legacy browser fix files"
echo "===================================================="
echo ""

STAMP="$(date +%Y%m%d-%H%M%S)"
TRASH="archive/deleted-old-things-$STAMP"
mkdir -p "$TRASH"

echo "[1/4] Keep important files:"
echo "  server.js"
echo "  start.sh"
echo "  install_browser_deps.sh"
echo "  package.json"
echo "  public/"
echo "  .devcontainer/"
echo "  node_modules/"
echo ""

echo "[2/4] Moving old junk into:"
echo "  $TRASH"
echo ""

# Old patch scripts and backups from previous attempts.
find . -maxdepth 1 -type f \( \
  -name "add_*.sh" -o \
  -name "fix_*.sh" -o \
  -name "setup_*.sh" -o \
  -name "install_cdp_touch_browser.sh" -o \
  -name "install_real_novnc_browser.sh" -o \
  -name "start_browser.sh" -o \
  -name "server.js.backup*" -o \
  -name "start.sh.backup*" -o \
  -name "*.bak" -o \
  -name "*.bak-*" -o \
  -name "*.bak-video-fix" -o \
  -name "fix-video-performance.py" -o \
  -name "browser-analysis-report.md" \
\) -print0 | while IFS= read -r -d '' file; do
  base="$(basename "$file")"

  # Never move the currently useful scripts.
  case "$base" in
    start.sh|server.js|install_browser_deps.sh|package.json)
      echo "KEEP: $base"
      ;;
    *)
      echo "MOVE: $base"
      mv "$file" "$TRASH/$base"
      ;;
  esac
done

echo ""
echo "[3/4] Checking project still works..."
node --check server.js

if [ -f package.json ]; then
  node -e "JSON.parse(require('fs').readFileSync('package.json','utf8')); console.log('package.json OK')"
fi

bash -n start.sh
bash -n install_browser_deps.sh

echo ""
echo "[4/4] Current clean root files:"
ls -la | sed -n '1,80p'

echo ""
echo "===================================================="
echo "Done."
echo "Old files moved to:"
echo "  $TRASH"
echo ""
echo "Start now with:"
echo "  ./start.sh"
echo ""
echo "If everything works and you want to permanently delete the moved old files:"
echo "  rm -rf \"$TRASH\""
echo "===================================================="
