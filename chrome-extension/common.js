// NetNewsList for Chrome and other Chromium browsers (Helium, Arc, Brave).
//
// Local mode: the Mac app is on this machine. Saving opens
// netnewslist://add?url=…&title=…, which the app handles without showing a window.
// The URL is opened from an extension page, not the web page, so Chrome's
// "Always allow" choice covers the extension once instead of every website.

export function isWebPage(url) {
  return /^https?:\/\//i.test(url || "");
}

// An extension's toolbar popup can't open netnewslist:// links: it isn't a tab, so the
// browser has nowhere to ask whether to open the app, and drops the link. Local mode
// opens this small window instead, from the toolbar button and the context menu alike.
export function openLocalSaveWindow(pageURL, title) {
  const query = new URLSearchParams({ url: pageURL || "", title: title || "" });
  return chrome.windows.create({
    url: chrome.runtime.getURL(`save.html?${query.toString()}`),
    type: "popup",
    width: 440,
    height: 220,
    focused: true
  });
}

// Percent-encoded, not URLSearchParams: that writes spaces as "+", which the app's
// URLComponents reads as a literal plus.
export function addURL(pageURL, title) {
  let link = `netnewslist://add?url=${encodeURIComponent(pageURL)}`;
  if (title && title.trim()) {
    link += `&title=${encodeURIComponent(title.trim())}`;
  }
  return link;
}
