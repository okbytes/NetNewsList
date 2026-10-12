import { addURL, isWebPage, openLocalSaveWindow } from "./common.js";
import { loadSettings } from "./lib/settings.js";

const status = document.getElementById("status");
const detail = document.getElementById("detail");
const actions = document.getElementById("actions");

// Opened by the toolbar button in remote mode (no query: save the active tab) or, in
// local mode, as a small window by the toolbar button or the context menu
// (?url=…&title=…: save that page).
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

// Hands the page to the app. When the browser opens the link straight away (the app
// saves in the background), the window says so and closes. When something takes the
// focus instead (the browser asks whether to open NetNewsList, or the app launches),
// it waits until the focus comes back, and closes after 20 seconds in any case.
function saveLocally(page) {
  const link = addURL(page.url, page.title);
  status.textContent = "Sending to NetNewsList…";
  let lostFocus = false;
  window.addEventListener("blur", () => {
    lostFocus = true;
    status.textContent = "Opening NetNewsList…";
    const hint = document.createElement("div");
    hint.id = "hint";
    hint.textContent = "If the browser asks, tick “Always allow” and choose Open.";
    detail.after(hint);
    addButton("Open Again", () => {
      location.href = link;
    });
    window.addEventListener("focus", () => setTimeout(() => window.close(), 400), { once: true });
  }, { once: true });
  setTimeout(() => {
    if (!lostFocus) {
      status.textContent = "Sent to NetNewsList";
      setTimeout(() => window.close(), 900);
    }
  }, 1200);
  setTimeout(() => window.close(), 20000);
  location.href = link;
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
  } else if (new URLSearchParams(location.search).has("url")) {
    saveLocally(page);
  } else {
    // Shown as the toolbar popup before the switch to local mode took effect.
    await openLocalSaveWindow(page.url, page.title);
    window.close();
  }
}

save().catch((error) => {
  status.textContent = `Couldn’t save: ${error.message}`;
});
