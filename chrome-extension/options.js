import { isWebPage } from "./common.js";
import { loadSettings, saveSettings } from "./lib/settings.js";

const fields = ["containerID", "environment", "apiToken", "callbackURL"];
const message = document.getElementById("message");

function show(text) {
  message.textContent = text || "";
}

async function send(type) {
  const response = await chrome.runtime.sendMessage({ type });
  if (response && response.ok === false && response.message) {
    show(response.message);
  }
  await refresh();
  return response;
}

function hint(text) {
  const line = document.createElement("div");
  line.className = "hint";
  line.textContent = text;
  return line;
}

function droppedItem(page) {
  const item = document.createElement("li");
  const name = page.title || page.url;
  if (isWebPage(page.url)) {
    const link = document.createElement("a");
    link.href = page.url;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.textContent = name;
    item.append(link);
  } else {
    item.append(name);
  }
  if (page.title) {
    item.append(hint(page.url));
  }
  item.append(hint(`${new Date(page.droppedAt).toLocaleString()}: ${page.reason}`));
  return item;
}

async function refresh() {
  const status = await chrome.runtime.sendMessage({ type: "status" });
  document.getElementById("problem").textContent = status.lastError || "";
  document.getElementById("account").textContent = status.signedIn ? "Signed in." : "Not signed in.";
  document.getElementById("queue").textContent = status.waiting === 0
    ? "Nothing is waiting."
    : `${status.waiting} ${status.waiting === 1 ? "page is" : "pages are"} waiting.`;
  document.getElementById("dropped").replaceChildren(...status.dropped.map(droppedItem));
  document.getElementById("droppedSection").hidden = status.dropped.length === 0;
}

async function load() {
  const settings = await loadSettings();
  for (const field of fields) {
    document.getElementById(field).value = settings[field] || "";
  }
  for (const radio of document.querySelectorAll("input[name=mode]")) {
    radio.checked = radio.value === settings.mode;
  }
  document.getElementById("remote").hidden = settings.mode !== "remote";
  await refresh();
}

for (const radio of document.querySelectorAll("input[name=mode]")) {
  radio.addEventListener("change", async () => {
    await saveSettings({ mode: radio.value });
    document.getElementById("remote").hidden = radio.value !== "remote";
    show(radio.value === "remote" ? "Saving straight to iCloud." : "Saving through the app on this Mac.");
  });
}

document.getElementById("save").addEventListener("click", async () => {
  const changes = {};
  for (const field of fields) {
    changes[field] = document.getElementById(field).value.trim();
  }
  await saveSettings(changes);
  show("Settings saved.");
});

document.getElementById("signIn").addEventListener("click", () => send("signIn"));
document.getElementById("signOut").addEventListener("click", () => send("signOut"));
document.getElementById("retry").addEventListener("click", () => send("retry"));
document.getElementById("clearDropped").addEventListener("click", () => send("clearDropped"));
document.getElementById("check").addEventListener("click", async () => {
  const response = await send("checkAccount");
  if (response?.ok) {
    show("iCloud accepted the sign-in.");
  }
});

// The sign-in finishes in another tab, and saves happen from the toolbar and the
// context menu: show what they changed.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local") {
    refresh();
  }
});

load();
