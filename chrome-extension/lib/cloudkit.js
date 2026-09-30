// A small CloudKit Web Services client: sign-in and the few record calls the
// extension needs. https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/
//
// The web auth token is good for one request: every response carries its
// replacement, which must be stored before the next request. Requests are
// therefore made one at a time.

import { zoneID } from "./records.js";

const API = "https://api.apple-cloudkit.com/database/1";
const TOKEN_HEADERS = ["x-apple-cloudkit-web-auth-token", "x-apple-cloudkit-session"];

export class SignInRequiredError extends Error {
  constructor(redirectURL) {
    super("Sign in to iCloud to save pages.");
    this.name = "SignInRequiredError";
    this.redirectURL = redirectURL;
  }
}

export class CloudKitError extends Error {
  constructor(serverErrorCode, reason) {
    super(reason ? `${reason} (${serverErrorCode})` : serverErrorCode);
    this.name = "CloudKitError";
    this.serverErrorCode = serverErrorCode;
  }
}

let lastRequest = Promise.resolve();

function serially(operation) {
  const result = lastRequest.then(operation, operation);
  lastRequest = result.catch(() => {});
  return result;
}

export async function webAuthToken() {
  const { webAuthToken } = await chrome.storage.local.get("webAuthToken");
  return webAuthToken || null;
}

export async function setWebAuthToken(token) {
  if (token) {
    await chrome.storage.local.set({ webAuthToken: token });
  } else {
    await chrome.storage.local.remove("webAuthToken");
  }
}

function databaseURL(settings, path, token) {
  const url = new URL(`${API}/${encodeURIComponent(settings.containerID)}/${settings.environment}/private/${path}`);
  // URLSearchParams encodes + / = in the token, as the reference asks.
  url.searchParams.set("ckAPIToken", settings.apiToken);
  if (token) {
    url.searchParams.set("ckWebAuthToken", token);
  }
  return url;
}

async function send(settings, path, body, useToken = true) {
  if (!settings.apiToken) {
    throw new CloudKitError("NO_API_TOKEN", "Add the CloudKit API token in the extension’s options");
  }
  const token = useToken ? await webAuthToken() : null;
  const response = await fetch(databaseURL(settings, path, token), {
    method: body ? "POST" : "GET",
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined
  });

  for (const header of TOKEN_HEADERS) {
    const newToken = response.headers.get(header);
    if (newToken) {
      await setWebAuthToken(newToken);
      break;
    }
  }

  const json = await response.json().catch(() => ({}));
  if (response.status === 421 || json.serverErrorCode === "AUTHENTICATION_REQUIRED") {
    if (useToken) {
      await setWebAuthToken(null);
    }
    throw new SignInRequiredError(json.redirectURL || null);
  }
  if (!response.ok) {
    throw new CloudKitError(json.serverErrorCode || `HTTP_${response.status}`, json.reason);
  }
  return json;
}

// The Apple sign-in page. After signing in it redirects to the API token's
// callback URL with ?ckWebAuthToken=…
export function signInURL(settings) {
  return serially(async () => {
    try {
      await send(settings, "users/current", null, false);
    } catch (error) {
      if (error instanceof SignInRequiredError && error.redirectURL) {
        return error.redirectURL;
      }
      throw error;
    }
    throw new CloudKitError("NO_SIGN_IN_URL", "CloudKit didn’t ask for a sign-in");
  });
}

export function currentUser(settings) {
  return serially(() => send(settings, "users/current", null));
}

export function lookupRecords(settings, recordNames) {
  return serially(() => send(settings, "records/lookup", {
    records: recordNames.map((recordName) => ({ recordName })),
    zoneID
  }));
}

export async function modifyRecords(settings, operations) {
  const json = await serially(() => send(settings, "records/modify", { operations, zoneID, atomic: true }));
  const failures = (json.records || []).filter((record) => record.serverErrorCode);
  const failure = failures.find((record) => record.serverErrorCode !== "ATOMIC_ERROR") || failures[0];
  if (failure) {
    throw new CloudKitError(failure.serverErrorCode, failure.reason);
  }
  return json;
}
