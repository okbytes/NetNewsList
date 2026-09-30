// Settings live in chrome.storage.local. Defaults can come from local-config.json
// next to the manifest: it isn't committed, so an API token placed there stays
// out of the repository.

export const defaultSettings = {
  mode: "local",
  containerID: "iCloud.eitherslice.NetNewsList",
  environment: "development",
  apiToken: "",
  callbackURL: ""
};

async function localConfig() {
  try {
    const response = await fetch(chrome.runtime.getURL("local-config.json"));
    return response.ok ? await response.json() : {};
  } catch {
    return {};
  }
}

export async function loadSettings() {
  const { settings } = await chrome.storage.local.get("settings");
  return { ...defaultSettings, ...(await localConfig()), ...(settings || {}) };
}

export async function saveSettings(changes) {
  const { settings } = await chrome.storage.local.get("settings");
  await chrome.storage.local.set({ settings: { ...(settings || {}), ...changes } });
}
