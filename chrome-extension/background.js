import { isWebPage, openLocalSaveWindow } from "./common.js";
import { SignInRequiredError, currentUser, setWebAuthToken, signInURL, useSignInToken } from "./lib/cloudkit.js";
import { clearDroppedPages, drainQueue, droppedPages, enqueue, queueLength } from "./lib/remote.js";
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

// Remote mode saves from the toolbar popup. Local mode has no popup: the button opens
// the small window that hands the page to the app (see openLocalSaveWindow).
async function applyActionPopup() {
  const settings = await loadSettings();
  await chrome.action.setPopup({ popup: settings.mode === "remote" ? "save.html" : "" });
}

applyActionPopup();

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.settings) {
    applyActionPopup();
  }
});

chrome.action.onClicked.addListener((tab) => {
  openLocalSaveWindow(tab.url, tab.title);
});

// The badge shows "!" while something needs attention (signed out, pages that
// can't be sent, pages that were dropped), otherwise how many pages are waiting.
async function updateBadge() {
  const { needsSignIn, lastError } = await chrome.storage.local.get(["needsSignIn", "lastError"]);
  const waiting = await queueLength();
  const dropped = (await droppedPages()).length;
  const failed = Boolean(needsSignIn || lastError || dropped > 0);
  let title = "Save to NetNewsList";
  if (lastError) {
    title = `NetNewsList: ${lastError}`;
  } else if (needsSignIn) {
    title = "NetNewsList: sign in to iCloud to save pages";
  } else if (dropped > 0) {
    title = `NetNewsList: ${dropped === 1 ? "a page" : `${dropped} pages`} couldn’t be saved; see the extension’s options`;
  }
  await chrome.action.setBadgeText({ text: failed ? "!" : waiting > 0 ? String(waiting) : "" });
  await chrome.action.setBadgeBackgroundColor({ color: failed ? "#d93025" : "#5f6368" });
  await chrome.action.setTitle({ title });
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
  if (outcome === "movedToQueue") {
    return { state: "saved", message: "Already saved; moved back to the Queue" };
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

// The context menu has no window to report in, so its outcome goes on the badge:
// a tick for a few seconds when the page is saved; otherwise updateBadge's "!"
// stays until the problem is gone, and the options page says what it was.
async function showOutcomeOnBadge(result) {
  if (result.state !== "saved") {
    await updateBadge();
    return;
  }
  await chrome.action.setBadgeText({ text: "✓" });
  await chrome.action.setBadgeBackgroundColor({ color: "#188038" });
  await chrome.action.setTitle({ title: `NetNewsList: ${result.message}` });
  setTimeout(updateBadge, 3000);
}

async function openSignIn() {
  const settings = await loadSettings();
  const url = await signInURL(settings);
  await chrome.tabs.create({ url });
}

async function status() {
  const settings = await loadSettings();
  const { webAuthToken, needsSignIn, lastError } = await chrome.storage.local.get(["webAuthToken", "needsSignIn", "lastError"]);
  return {
    mode: settings.mode,
    signedIn: Boolean(webAuthToken) && !needsSignIn,
    waiting: await queueLength(),
    lastError: lastError || null,
    dropped: await droppedPages()
  };
}

// After CloudKit accepts the sign-in: clear the old problem and send what's waiting
// (which records a new problem if pages still can't be sent).
async function signedIn() {
  await chrome.storage.local.set({ needsSignIn: false, lastError: null });
  await drainAndUpdateBadge();
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
    await signedIn();
    return { ok: true, userRecordName: user.userRecordName };
  },
  clearDropped: async () => {
    await clearDroppedPages();
    await updateBadge();
    return { ok: true };
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

// Only the callback URL's own origin counts: a prefix check would also accept
// https://callback.example.attacker.example/.
function isSignInCallback(url, callbackURL) {
  if (!isWebPage(callbackURL)) {
    return false;
  }
  try {
    return new URL(url).origin === new URL(callbackURL).origin;
  } catch {
    return false;
  }
}

function signInFailure(error) {
  if (error instanceof SignInRequiredError) {
    return "iCloud didn’t accept the sign-in. In CloudKit Console, check the API token’s environment, sign-in callback and allowed origins, then sign in again.";
  }
  return `Couldn’t check the sign-in with iCloud: ${error.message}`;
}

// Apple's sign-in page ends by sending the browser to the API token's callback
// URL with ?ckWebAuthToken=…. Take the token, close the tab, and spend the token at
// once (see useSignInToken), which also checks that CloudKit accepts it.
chrome.webNavigation.onBeforeNavigate.addListener(async (details) => {
  if (details.frameId !== 0) {
    return;
  }
  const settings = await loadSettings();
  if (!isSignInCallback(details.url, settings.callbackURL)) {
    return;
  }
  const token = new URL(details.url).searchParams.get("ckWebAuthToken");
  if (!token) {
    return;
  }
  chrome.tabs.remove(details.tabId).catch(() => {});
  try {
    await useSignInToken(settings, token);
  } catch (error) {
    await chrome.storage.local.set({ needsSignIn: true, lastError: signInFailure(error) });
    await updateBadge();
    return;
  }
  await signedIn();
}, { url: [{ queryContains: "ckWebAuthToken=" }] });

chrome.contextMenus.onClicked.addListener(async (info) => {
  if (info.menuItemId !== "save-link" || !isWebPage(info.linkUrl)) {
    return;
  }
  const settings = await loadSettings();
  if (settings.mode === "remote") {
    let result;
    try {
      result = await saveRemotely({ url: info.linkUrl, title: info.selectionText || "" });
    } catch (error) {
      await chrome.storage.local.set({ lastError: error.message });
      result = { state: "error", message: error.message };
    }
    await showOutcomeOnBadge(result);
    return;
  }
  openLocalSaveWindow(info.linkUrl, info.selectionText);
});
