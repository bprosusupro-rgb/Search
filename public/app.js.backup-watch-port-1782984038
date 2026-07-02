const addressInput = document.getElementById("addressInput");
const keyboardBox = document.getElementById("keyboardBox");
const toastEl = document.getElementById("toast");

function toast(text) {
  toastEl.textContent = text;
  toastEl.classList.add("visible");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => toastEl.classList.remove("visible"), 2200);
}

async function postJson(url, body) {
  const r = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store"
    },
    body: JSON.stringify(body)
  });

  const data = await r.json().catch(() => ({}));

  if (!data.ok) {
    throw new Error(data.error || "Request failed.");
  }

  return data;
}

async function navigate() {
  const value = addressInput.value.trim();
  if (!value) return;

  try {
    toast("Opening...");
    const data = await postJson("/api/navigate", { url: value });
    addressInput.value = data.url || value;
    toast("Opened");
  } catch (error) {
    toast(error.message);
  }
}

document.getElementById("goBtn").onclick = navigate;

addressInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") navigate();
});

document.getElementById("reloadBtn").onclick = async () => {
  try {
    await postJson("/api/key", { key: "F5" });
  } catch {
    location.reload();
  }
};

document.getElementById("focusBtn").onclick = () => {
  document.body.classList.toggle("focus");
};

document.getElementById("keyboardBtn").onclick = () => {
  keyboardBox.classList.toggle("visible");

  if (keyboardBox.classList.contains("visible")) {
    keyboardBox.value = "";
    keyboardBox.focus();
    toast("Keyboard open. Tap a remote field first, then type here.");
  } else {
    keyboardBox.blur();
  }
};

keyboardBox.addEventListener("input", async (event) => {
  const value = keyboardBox.value;

  if (event.inputType === "deleteContentBackward") {
    await postJson("/api/key", { key: "Backspace" }).catch(() => {});
    keyboardBox.value = "";
    return;
  }

  if (!value) return;

  await postJson("/api/text", { text: value.replace(/\n/g, "") }).catch(() => {});
  keyboardBox.value = "";
});

keyboardBox.addEventListener("keydown", async (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    await postJson("/api/key", { key: "Enter" }).catch(() => {});
  }

  if (event.key === "Backspace") {
    event.preventDefault();
    await postJson("/api/key", { key: "Backspace" }).catch(() => {});
    keyboardBox.value = "";
  }

  if (event.key === "Tab") {
    event.preventDefault();
    await postJson("/api/key", { key: "Tab" }).catch(() => {});
  }
});


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

document.getElementById("ytBackBtn").onclick = () => {
  postJson("/api/youtube", { action: "seek", seconds: -10 }).then(() => toast("-10 seconds")).catch(() => toast("No YouTube video found"));
};

document.getElementById("ytPlayBtn").onclick = () => {
  postJson("/api/youtube", { action: "togglePlay" }).then(() => toast("Play/Pause")).catch(() => toast("No YouTube video found"));
};

document.getElementById("ytForwardBtn").onclick = () => {
  postJson("/api/youtube", { action: "seek", seconds: 10 }).then(() => toast("+10 seconds")).catch(() => toast("No YouTube video found"));
};
