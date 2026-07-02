#!/usr/bin/env bash
set -e

echo "Patching browser to report German locale, timezone, geolocation, and German search region..."

pkill -f "node server.js" 2>/dev/null || true
pkill -f "chromium" 2>/dev/null || true
pkill -f "Xvfb" 2>/dev/null || true
sleep 1

if [ ! -f server.js ]; then
  echo "ERROR: server.js not found."
  exit 1
fi

cp server.js "server.js.backup-germany-$(date +%s)"

node --input-type=commonjs <<'NODE'
const fs = require("fs");

let s = fs.readFileSync("server.js", "utf8");

if (!s.includes("const GERMANY_BROWSER_LOCATION")) {
  s = s.replace(
    `const DISPLAY_NUM = ":99";`,
    `const DISPLAY_NUM = ":99";

const GERMANY_BROWSER_LOCATION = {
  locale: "de-DE",
  acceptLanguage: "de-DE,de;q=0.9,en-US;q=0.6,en;q=0.5",
  timezone: "Europe/Berlin",
  latitude: 52.520008,
  longitude: 13.404954,
  accuracy: 50
};`
  );
}

// German env for Chromium process
s = s.replace(
  `DISPLAY: DISPLAY_NUM,
    HOME: homeDir,`,
  `DISPLAY: DISPLAY_NUM,
    HOME: homeDir,
    TZ: GERMANY_BROWSER_LOCATION.timezone,
    LANG: "de_DE.UTF-8",
    LANGUAGE: "de_DE:de",`
);

// German Chromium launch flags
if (!s.includes("--lang=de-DE")) {
  s = s.replace(
    `"--no-first-run",`,
    `"--lang=de-DE",
      \`--accept-lang=\${GERMANY_BROWSER_LOCATION.acceptLanguage}\`,
      "--no-first-run",`
  );
}

// German Accept-Language for server-side fetches/search/reader
if (!s.includes(`"Accept-Language": GERMANY_BROWSER_LOCATION.acceptLanguage`)) {
  s = s.replace(
    `"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5",`,
    `"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5",
      "Accept-Language": GERMANY_BROWSER_LOCATION.acceptLanguage,`
  );
}

// German DuckDuckGo region
s = s.replace(
  /const searchUrl = `https:\/\/html\.duckduckgo\.com\/html\/\?q=\$\{encodeURIComponent$begin:math:text$q$end:math:text$\}`;/g,
  `const searchUrl = \`https://html.duckduckgo.com/html/?kl=de-de&kad=de_DE&q=\${encodeURIComponent(q)}\`;`
);

// Add reusable Germany CDP config
if (!s.includes("async function configureGermanyLocation")) {
  const germanyFn = `
async function configureGermanyLocation(sendCommand = oneShotCdp) {
  try {
    await sendCommand("Emulation.setTimezoneOverride", {
      timezoneId: GERMANY_BROWSER_LOCATION.timezone
    });
  } catch {}

  try {
    await sendCommand("Emulation.setLocaleOverride", {
      locale: GERMANY_BROWSER_LOCATION.locale
    });
  } catch {}

  try {
    await sendCommand("Emulation.setGeolocationOverride", {
      latitude: GERMANY_BROWSER_LOCATION.latitude,
      longitude: GERMANY_BROWSER_LOCATION.longitude,
      accuracy: GERMANY_BROWSER_LOCATION.accuracy
    });
  } catch {}

  try {
    await sendCommand("Browser.grantPermissions", {
      permissions: ["geolocation"]
    });
  } catch {}
}

`;

  s = s.replace(`async function configureTouch()`, germanyFn + `async function configureTouch()`);
}

// Make configureTouch also apply Germany
s = s.replace(
  `async function configureTouch() {
  try {
    await oneShotCdp("Emulation.setTouchEmulationEnabled", {
      enabled: true,
      maxTouchPoints: 5
    });
  } catch {}
}`,
  `async function configureTouch() {
  try {
    await oneShotCdp("Emulation.setTouchEmulationEnabled", {
      enabled: true,
      maxTouchPoints: 5
    });
  } catch {}

  await configureGermanyLocation(oneShotCdp);
}`
);

// Apply Germany config when the CDP renderer connects
if (!s.includes("GERMANY_LOCATION_RENDERER_PATCH")) {
  s = s.replace(
    `await sendChrome("Emulation.setTouchEmulationEnabled", {
        enabled: true,
        maxTouchPoints: 5
      });`,
    `await sendChrome("Emulation.setTouchEmulationEnabled", {
        enabled: true,
        maxTouchPoints: 5
      });

      // GERMANY_LOCATION_RENDERER_PATCH
      await configureGermanyLocation(sendChrome);`
  );
}

// Add simple test endpoint
if (!s.includes(`app.get("/api/germany-location-test"`)) {
  s = s.replace(
    `app.get("/api/real/status", (req, res) => {`,
    `app.get("/api/germany-location-test", async (req, res) => {
  try {
    await configureGermanyLocation(oneShotCdp);

    const result = await oneShotCdp("Runtime.evaluate", {
      expression: "({ language: navigator.language, languages: navigator.languages, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, href: location.href })",
      returnByValue: true
    });

    res.json({
      ok: true,
      intended_location: "Germany / Berlin",
      note: "This changes browser locale/timezone/geolocation signals, not GitHub Codespaces' real IP.",
      chromium_reported: result?.result?.value || null
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message || String(error)
    });
  }
});

app.get("/api/real/status", (req, res) => {`
  );
}

fs.writeFileSync("server.js", s);
NODE

echo ""
echo "Patch installed."
echo ""
echo "What this changes:"
echo "- Browser language: de-DE"
echo "- Accept-Language: German"
echo "- Timezone: Europe/Berlin"
echo "- Geolocation API: Berlin, Germany"
echo "- DuckDuckGo region: Germany"
echo "- Cookies/profile still deleted on restart"
echo ""
echo "What it cannot change:"
echo "- The real GitHub Codespaces server IP location"
echo ""

npm install --no-package-lock

echo ""
echo "Starting browser..."
PORT=7860 npm start
