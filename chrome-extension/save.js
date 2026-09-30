import { addURL, isWebPage } from "./common.js";
import { loadSettings } from "./lib/settings.js";

const status = document.getElementById("status");
const detail = document.getElementById("detail");
const actions = document.getElementById("actions");

// Opened by the toolbar button (no query: save the active tab) or, in local
// mode, by the context menu (?url=…&title=…: save that link).
async function pageToSave() {
  const query = new URLSearchParams(location.search);
  if (query.has("url")) {
    return { url: query.get("url"), title: query.get("title") || "" };
  }
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return { url: tab ? tab.url : "", title: tab ? tab.title : "" };
}

function addButton(title, action) {
  const button = document.createElement("button");
  button.textContent = title;
  button.addEventListener("click", action);
  actions.append(button);
}

function saveLocally(page) {
  location.href = addURL(page.url, page.title);
  status.textContent = "Sent to NetNewsList";
  setTimeout(() => window.close(), 1500);
}

async function saveRemotely(page) {
  const result = await chrome.runtime.sendMessage({ type: "save", url: page.url, title: page.title });
  status.textContent = result.message;
  if (result.state === "needsSignIn") {
    addButton("Sign In to iCloud", async () => {
      await chrome.runtime.sendMessage({ type: "signIn" });
      window.close();
    });
    return;
  }
  if (result.state === "queued" || result.state === "error") {
    addButton("Options", () => chrome.runtime.openOptionsPage());
    return;
  }
  setTimeout(() => window.close(), 1500);
}

async function save() {
  const page = await pageToSave();
  if (!isWebPage(page.url)) {
    status.textContent = "Only web pages can be saved.";
    return;
  }
  detail.textContent = page.title || page.url;
  const settings = await loadSettings();
  if (settings.mode === "remote") {
    await saveRemotely(page);
  } else {
    saveLocally(page);
  }
}

save().catch((error) => {
  status.textContent = `Couldn’t save: ${error.message}`;
});
