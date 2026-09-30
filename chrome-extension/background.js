import { isWebPage } from "./common.js";
import { SignInRequiredError, currentUser, setWebAuthToken, signInURL } from "./lib/cloudkit.js";
import { drainQueue, enqueue, queueLength } from "./lib/remote.js";
import { loadSettings } from "./lib/settings.js";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "save-link",
    title: "Save Link to NetNewsList",
    contexts: ["link"]
  });
  updateBadge();
});

chrome.runtime.onStartup.addListener(() => {
  drainAndUpdateBadge();
});

async function updateBadge() {
  const { needsSignIn } = await chrome.storage.local.get("needsSignIn");
  const waiting = await queueLength();
  const text = needsSignIn ? "!" : waiting > 0 ? String(waiting) : "";
  await chrome.action.setBadgeText({ text });
  await chrome.action.setBadgeBackgroundColor({ color: needsSignIn ? "#d93025" : "#5f6368" });
  await chrome.action.setTitle({ title: needsSignIn ? "NetNewsList: sign in to iCloud to save pages" : "Save to NetNewsList" });
}

async function drainAndUpdateBadge() {
  const outcome = await drainQueue();
  await updateBadge();
  return outcome;
}

// Remote mode: queue the page, then try to write everything queued.
async function saveRemotely(page) {
  if (!isWebPage(page.url)) {
    return { state: "error", message: "Only web pages can be saved." };
  }
  await enqueue(page);
  const { results, stoppedBy } = await drainAndUpdateBadge();
  const outcome = results.get(page.url);
  if (outcome === "saved") {
    return { state: "saved", message: "Saved to NetNewsList" };
  }
  if (outcome === "movedToInbox") {
    return { state: "saved", message: "Already saved; moved back to the Inbox" };
  }
  if (outcome === "alreadySaved") {
    return { state: "saved", message: "Already in NetNewsList" };
  }
  if (outcome instanceof Error) {
    return { state: "error", message: outcome.message };
  }
  if (stoppedBy instanceof SignInRequiredError) {
    return { state: "needsSignIn", message: "Saved for later. Sign in to iCloud to send it." };
  }
  return { state: "queued", message: `Saved for later: ${stoppedBy ? stoppedBy.message : "not sent yet"}` };
}

async function openSignIn() {
  const settings = await loadSettings();
  const url = await signInURL(settings);
  await chrome.tabs.create({ url });
}

async function status() {
  const settings = await loadSettings();
  const { webAuthToken, needsSignIn, lastError } = await chrome.storage.local.get(["webAuthToken", "needsSignIn", "lastError"]);
  return { mode: settings.mode, signedIn: Boolean(webAuthToken) && !needsSignIn, waiting: await queueLength(), lastError: lastError || null };
}

const handlers = {
  save: (message) => saveRemotely({ url: message.url, title: message.title }),
  signIn: () => openSignIn().then(() => ({ ok: true })),
  signOut: async () => {
    await setWebAuthToken(null);
    await chrome.storage.local.set({ needsSignIn: true });
    await updateBadge();
    return { ok: true };
  },
  retry: async () => {
    const { stoppedBy } = await drainAndUpdateBadge();
    return { ok: !stoppedBy, message: stoppedBy ? stoppedBy.message : null };
  },
  checkAccount: async () => {
    const user = await currentUser(await loadSettings());
    await chrome.storage.local.set({ needsSignIn: false });
    await updateBadge();
    return { ok: true, userRecordName: user.userRecordName };
  },
  status
};

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const handler = handlers[message?.type];
  if (!handler) {
    return false;
  }
  handler(message)
    .then(sendResponse)
    .catch((error) => sendResponse({ state: "error", ok: false, message: error.message, needsSignIn: error instanceof SignInRequiredError }));
  return true;
});

// Apple's sign-in page ends by sending the browser to the API token's callback
// URL with ?ckWebAuthToken=…. Take the token and close the tab.
chrome.webNavigation.onBeforeNavigate.addListener(async (details) => {
  if (details.frameId !== 0) {
    return;
  }
  const settings = await loadSettings();
  if (!settings.callbackURL || !details.url.startsWith(new URL(settings.callbackURL).origin)) {
    return;
  }
  const token = new URL(details.url).searchParams.get("ckWebAuthToken");
  if (!token) {
    return;
  }
  await setWebAuthToken(token);
  await chrome.storage.local.set({ needsSignIn: false, lastError: null });
  chrome.tabs.remove(details.tabId).catch(() => {});
  await drainAndUpdateBadge();
}, { url: [{ queryContains: "ckWebAuthToken=" }] });

chrome.contextMenus.onClicked.addListener(async (info) => {
  if (info.menuItemId !== "save-link" || !isWebPage(info.linkUrl)) {
    return;
  }
  const settings = await loadSettings();
  if (settings.mode === "remote") {
    await saveRemotely({ url: info.linkUrl, title: info.selectionText || "" });
    return;
  }
  const query = new URLSearchParams({ url: info.linkUrl, title: info.selectionText || "" });
  chrome.windows.create({
    url: `save.html?${query.toString()}`,
    type: "popup",
    width: 360,
    height: 140,
    focused: true
  });
});
