import { isWebPage } from "./common.js";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "save-link",
    title: "Save Link to NetNewsList",
    contexts: ["link"]
  });
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId !== "save-link" || !isWebPage(info.linkUrl)) {
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
