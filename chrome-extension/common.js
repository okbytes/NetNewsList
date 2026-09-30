// NetNewsList for Chrome and other Chromium browsers (Helium, Arc, Brave).
//
// Local mode: the Mac app is on this machine. Saving opens
// netnewslist://add?url=…&title=…, which the app handles without showing a window.
// The URL is opened from an extension page, not the web page, so Chrome's
// "Always allow" choice covers the extension once instead of every website.

export function isWebPage(url) {
  return /^https?:\/\//i.test(url || "");
}

export function addURL(pageURL, title) {
  const params = new URLSearchParams({ url: pageURL });
  if (title && title.trim()) {
    params.set("title", title.trim());
  }
  return `netnewslist://add?${params.toString()}`;
}
