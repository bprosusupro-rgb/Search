# Real Browser

A remote Chromium browser for GitHub Codespaces. Express serves the controls and proxies a real X11 Chromium desktop through noVNC. Port `7860` is the interactive browser; port `7861` is a separate watch only stream.

## Run in Codespaces

Open the repository in a Codespace, then run this from the repository root:

```bash
bash start.sh
```

The script installs missing browser dependencies, installs the Node packages, starts Chromium and prints the forwarded browser links. Codespaces forwards ports `7860` and `7861` from `.devcontainer/devcontainer.json`.

The main page has touch, scroll, and watch modes, an immersive view, remote keyboard input, video controls, and three stream quality settings. Choose **Fast video** on a slower connection. Open **Watch tab** to use the separate view only port.

To refresh an existing Codespace with the latest GitHub changes and start it again:

```bash
git pull --ff-only && bash start.sh
```

Saved Chromium session data stays in `.browser_state/` and is ignored by Git.
