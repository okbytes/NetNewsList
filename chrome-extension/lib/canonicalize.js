// The same rules as URLCanonicalizer.swift, including Foundation's quirks, so that
// the extension and the apps compute the same article ID for a page. Both are
// checked against Modules/Account/Tests/AccountTests/Resources/url-canonicalization.json.

const TRACKING_QUERY_ITEM_NAMES = new Set(["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"]);

// RFC 3986, appendix B.
const URI_PARTS = /^([A-Za-z][A-Za-z0-9+.-]*):(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/s;

// Foundation percent-encodes these when it parses a URL string, plus anything
// outside ASCII (as UTF-8), and turns a % that doesn't start an escape into %25.
const INVALID_ASCII = /[\x00-\x20"<>[\\\]^`{|}\x7F]/g;
const NON_ASCII = /[^\x00-\x7F]+/gu;

function hex(code) {
  return "%" + code.toString(16).toUpperCase().padStart(2, "0");
}

function encodeInvalidCharacters(string) {
  return string
    .replace(/%(?![0-9A-Fa-f]{2})/g, "%25")
    .replace(INVALID_ASCII, (character) => hex(character.charCodeAt(0)))
    .replace(NON_ASCII, (characters) => encodeURIComponent(characters));
}

function decodedName(item) {
  const encodedName = item.split("=", 1)[0];
  try {
    return decodeURIComponent(encodedName).toLowerCase();
  } catch {
    return encodedName.toLowerCase();
  }
}

// Returns the canonical form of an http or https URL, or null for anything else.
export function canonicalize(urlString) {
  const match = URI_PARTS.exec(String(urlString).trim());
  if (!match) {
    return null;
  }
  const scheme = match[1].toLowerCase();
  const authority = match[2];
  if ((scheme !== "http" && scheme !== "https") || authority === undefined) {
    return null;
  }

  let userInfo = null;
  let hostAndPort = authority;
  const at = authority.lastIndexOf("@");
  if (at >= 0) {
    userInfo = authority.slice(0, at);
    hostAndPort = authority.slice(at + 1);
  }

  let host;
  let port = "";
  if (hostAndPort.startsWith("[")) {
    const end = hostAndPort.indexOf("]");
    if (end < 0) {
      return null;
    }
    host = hostAndPort.slice(0, end + 1);
    const rest = hostAndPort.slice(end + 1);
    if (rest.startsWith(":")) {
      port = rest.slice(1);
    } else if (rest) {
      return null;
    }
  } else {
    const colon = hostAndPort.lastIndexOf(":");
    host = colon >= 0 ? hostAndPort.slice(0, colon) : hostAndPort;
    port = colon >= 0 ? hostAndPort.slice(colon + 1) : "";
  }
  if (!host || (port && !/^\d+$/.test(port))) {
    return null;
  }

  host = host.toLowerCase();
  if (/[^\x00-\x7F]/.test(host)) {
    try {
      host = new URL(`http://${host}/`).hostname;
    } catch {
      return null;
    }
  }

  let portNumber = port === "" ? null : parseInt(port, 10);
  if ((scheme === "http" && portNumber === 80) || (scheme === "https" && portNumber === 443)) {
    portNumber = null;
  }

  let path = encodeInvalidCharacters(match[3] || "");
  if (path === "") {
    path = "/";
  } else if (path.length > 1 && path.endsWith("/")) {
    path = path.slice(0, -1);
  }

  let query = match[4] === undefined ? null : encodeInvalidCharacters(match[4]);
  if (query !== null) {
    const kept = query.split("&").filter((item) => {
      const name = decodedName(item);
      return !name.startsWith("utm_") && !TRACKING_QUERY_ITEM_NAMES.has(name);
    });
    query = kept.join("&");
    if (query === "") {
      query = null;
    }
  }

  let canonical = `${scheme}://`;
  if (userInfo !== null) {
    canonical += `${encodeInvalidCharacters(userInfo)}@`;
  }
  canonical += host;
  if (portNumber !== null) {
    canonical += `:${portNumber}`;
  }
  canonical += path;
  if (query !== null) {
    canonical += `?${query}`;
  }
  return canonical;
}
