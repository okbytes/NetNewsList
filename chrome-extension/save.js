import { addURL, isWebPage } from "./common.js";

const status = document.getElementById("status");
const detail = document.getElementById("detail");

// Opened by the toolbar button (no query: save the active tab) or by the
// context menu (?url=…&title=…: save that link).
async function pageToSave() {
  const query = new URLSearchParams(location.search);
  if (query.has("url")) {
    return { url: query.get("url"), title: query.get("title") || "" };
  }
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return { url: tab ? tab.url : "", title: tab ? tab.title : "" };
}

async function save() {
  const page = await pageToSave();
  if (!isWebPage(page.url)) {
    status.textContent = "Only web pages can be saved.";
    return;
  }
  detail.textContent = page.title || page.url;
  location.href = addURL(page.url, page.title);
  status.textContent = "Sent to NetNewsList";
  setTimeout(() => window.close(), 1500);
}

save();
