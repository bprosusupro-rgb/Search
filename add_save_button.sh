#!/usr/bin/env bash
set -e

echo "Adding Save button and persistent browser state..."

if [ ! -f server.js ]; then
  echo "ERROR: server.js not found."
  exit 1
fi

if [ ! -f public/index.html ]; then
  echo "ERROR: public/index.html not found."
  exit 1
fi

if [ ! -f public/app.js ]; then
  echo "ERROR: public/app.js not found."
  exit 1
fi

cp server.js "server.js.backup-save-$(date +%s)"
cp public/index.html "public/index.html.backup-save-$(date +%s)"
cp public/app.js "public/app.js.backup-save-$(date +%s)"

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let s = fs.readFileSync("server.js", "utf8");

if (!s.includes("const SAVED_STATE_DIR")) {
  s = s.replace(
    `let tempRoot = null;
let children = [];`,
    `let tempRoot = null;
let children = [];
let currentProfileDir = null;

const SAVED_STATE_DIR = path.join(__dirname, ".browser_state");
const SAVED_PROFILE_DIR = path.join(SAVED_STATE_DIR, "profile");
const SAVED_INFO_FILE = path.join(SAVED_STATE_DIR, "state.json");

function cleanupProfileRuntimeFiles(profileDir) {
  if (!profileDir || !fs.existsSync(profileDir)) return;

  for (const name of [
    "SingletonLock",
    "SingletonCookie",
    "SingletonSocket",
    "BrowserMetrics",
    "Crashpad",
    "Default/LOCK",
    "Default/SingletonLock",
    "Default/SingletonCookie",
    "Default/SingletonSocket"
  ]) {
    try {
      fs.rmSync(path.join(profileDir, name), { recursive: true, force: true });
    } catch {}
  }
}`
  );
}

if (!s.includes("currentProfileDir = profileDir;")) {
  s = s.replace(
    `fs.chmodSync(runtimeDir, 0o700);

  const env = {`,
    `fs.chmodSync(runtimeDir, 0o700);

  currentProfileDir = profileDir;

  if (fs.existsSync(SAVED_PROFILE_DIR)) {
    console.log("Restoring saved browser state from .browser_state/profile ...");
    fs.cpSync(SAVED_PROFILE_DIR, profileDir, {
      recursive: true,
      force: true,
      errorOnExist: false
    });
    cleanupProfileRuntimeFiles(profileDir);
  }

  const env = {`
  );
}

if (!s.includes(`app.post("/api/save-state"`)) {
  const saveApi = `
app.get("/api/save-state-info", (req, res) => {
  let info = null;

  try {
    if (fs.existsSync(SAVED_INFO_FILE)) {
      info = JSON.parse(fs.readFileSync(SAVED_INFO_FILE, "utf8"));
    }
  } catch {}

  res.json({
    ok: true,
    hasSavedState: fs.existsSync(SAVED_PROFILE_DIR),
    info
  });
});

app.post("/api/save-state", async (req, res) => {
  try {
    if (!currentProfileDir || !fs.existsSync(currentProfileDir)) {
      throw new Error("No running Chromium profile found.");
    }

    let currentUrl = "";

    try {
      const result = await cdp("Runtime.evaluate", {
        expression: "location.href",
        returnByValue: true
      });

      currentUrl = result?.result?.value || "";
    } catch {}

    fs.rmSync(SAVED_STATE_DIR, {
      recursive: true,
      force: true
    });

    fs.mkdirSync(SAVED_STATE_DIR, {
      recursive: true
    });

    cleanupProfileRuntimeFiles(currentProfileDir);

    fs.cpSync(currentProfileDir, SAVED_PROFILE_DIR, {
      recursive: true,
      force: true,
      errorOnExist: false
    });

    cleanupProfileRuntimeFiles(SAVED_PROFILE_DIR);

    const info = {
      savedAt: new Date().toISOString(),
      url: currentUrl,
      note: "This saved browser profile can include cookies and login sessions. Do not commit it publicly."
    };

    fs.writeFileSync(SAVED_INFO_FILE, JSON.stringify(info, null, 2));

    res.json({
      ok: true,
      savedAt: info.savedAt,
      url: currentUrl,
      path: ".browser_state/"
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

app.post("/api/delete-saved-state", (req, res) => {
  try {
    fs.rmSync(SAVED_STATE_DIR, {
      recursive: true,
      force: true
    });

    res.json({
      ok: true
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

`;

  s = s.replace(`app.get("/api/germany-test"`, saveApi + `app.get("/api/germany-test"`);
}

fs.writeFileSync("server.js", s);
NODE

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let html = fs.readFileSync("public/index.html", "utf8");

if (!html.includes('id="saveBtn"')) {
  html = html.replace(
    `<button id="keyboardBtn">Keyboard</button>`,
    `<button id="keyboardBtn">Keyboard</button>
      <button id="saveBtn">Save</button>`
  );
}

fs.writeFileSync("public/index.html", html);
NODE

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let js = fs.readFileSync("public/app.js", "utf8");

if (!js.includes('document.getElementById("saveBtn")')) {
  const saveCode = `
const saveBtn = document.getElementById("saveBtn");

if (saveBtn) {
  saveBtn.onclick = async () => {
    try {
      toast("Saving browser state...");
      const data = await postJson("/api/save-state", {});
      toast("Saved state to .browser_state/");
      console.log("Saved browser state:", data);
    } catch (error) {
      toast(error.message || "Save failed.");
    }
  };
}

`;

  js = js.replace(
    `document.getElementById("ytBackBtn").onclick = () => {`,
    saveCode + `document.getElementById("ytBackBtn").onclick = () => {`
  );
}

fs.writeFileSync("public/app.js", js);
NODE

if [ -f .gitignore ]; then
  grep -qxF ".browser_state/" .gitignore || echo ".browser_state/" >> .gitignore
else
  echo ".browser_state/" > .gitignore
fi

chmod +x start.sh 2>/dev/null || true

echo ""
echo "===================================================="
echo "Save button added."
echo ""
echo "When you press Save, the browser profile is saved to:"
echo ".browser_state/"
echo ""
echo "It will restore automatically next time you start the browser."
echo "The folder is in .gitignore because it can contain cookies/login data."
echo "===================================================="
echo ""

echo "Restarting browser..."
./start.sh
