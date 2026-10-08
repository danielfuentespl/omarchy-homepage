"use strict";

// Pure validation and response normalization shared by QML and tests.
const LIMITS = Object.freeze({
  responseBytes: 512 * 1024,
  groups: 128,
  services: 500,
  depth: 12,
  groupName: 120,
  name: 160,
  description: 500,
  href: 2048,
  icon: 160,
  metadata: 160
});

function cleanText(value, max) {
  if (typeof value !== "string") return "";
  return value.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, max).trim();
}

function validPort(value) {
  if (value === "") return true;
  if (!/^[0-9]{1,5}$/.test(value)) return false;
  const port = Number(value);
  return port >= 1 && port <= 65535;
}

function validIPv4(host) {
  const parts = host.split(".");
  return parts.length === 4 && parts.every(part => /^(0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255);
}

function validIPv6(host) {
  if (!host || !/^[0-9a-f:.]+$/i.test(host) || (host.match(/::/g) || []).length > 1) return false;
  if (host.indexOf(".") !== -1) {
    const split = host.lastIndexOf(":");
    if (split < 0 || !validIPv4(host.slice(split + 1))) return false;
    host = host.slice(0, split) + ":0:0";
  }
  const halves = host.split("::");
  const parts = [];
  for (let i = 0; i < halves.length; ++i) {
    if (halves[i]) {
      const halfParts = halves[i].split(":");
      for (let j = 0; j < halfParts.length; ++j) parts.push(halfParts[j]);
    }
  }
  if (!parts.every(part => /^[0-9a-f]{1,4}$/i.test(part))) return false;
  return halves.length === 2 ? parts.length < 8 : parts.length === 8;
}

function validDnsHost(host) {
  if (!host || host.length > 253 || host.indexOf("..") !== -1) return false;
  const normalized = host.endsWith(".") ? host.slice(0, -1) : host;
  if (/^[0-9.]+$/.test(normalized)) return validIPv4(normalized);
  return normalized.split(".").every(label =>
    label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(label));
}

function splitAuthority(authority) {
  if (!authority || authority.indexOf("@") !== -1 || /[\s\\\u0000-\u001f\u007f]/.test(authority)) return null;
  let host = "";
  let port = "";
  if (authority.charAt(0) === "[") {
    const close = authority.indexOf("]");
    if (close < 0) return null;
    host = authority.slice(1, close);
    const suffix = authority.slice(close + 1);
    if (suffix && suffix.charAt(0) !== ":") return null;
    port = suffix ? suffix.slice(1) : "";
    if (!validIPv6(host)) return null;
    return { host: "[" + host.toLowerCase() + "]", port };
  }
  const colon = authority.lastIndexOf(":");
  if (colon >= 0) {
    if (authority.indexOf(":") !== colon) return null;
    host = authority.slice(0, colon);
    port = authority.slice(colon + 1);
  } else host = authority;
  if (!validDnsHost(host)) return null;
  return { host: host.toLowerCase().replace(/\.$/, ""), port };
}

function parseHttpUrl(value, options) {
  const opts = options || {};
  if (typeof value !== "string" || value.length === 0 || value.length > (opts.maxLength || LIMITS.href)) return null;
  if (/[\s\\\u0000-\u001f\u007f]/.test(value)) return null;
  const match = /^(https?):\/\/([^/?#]+)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(value);
  if (!match) return null;
  const authority = splitAuthority(match[2]);
  if (!authority || !validPort(authority.port)) return null;
  const path = match[3] || "";
  if (/%(?![0-9a-f]{2})/i.test(path + (match[4] || "") + (match[5] || ""))) return null;
  if (opts.originOnly && ((match[4] || "") !== "" || (match[5] || "") !== "")) return null;
  return {
    scheme: match[1].toLowerCase(),
    authority,
    path,
    query: match[4] || "",
    fragment: match[5] || ""
  };
}

function safeHttpUrl(raw, maxLength) {
  const parsed = parseHttpUrl(raw, { maxLength: maxLength || LIMITS.href });
  return parsed ? raw : "";
}

function normalizeBaseUrl(raw) {
  if (typeof raw !== "string") return { ok: false, value: "", error: "Enter a valid Homepage HTTP(S) address." };
  const text = raw.trim();
  const parsed = parseHttpUrl(text, { maxLength: 2048, originOnly: true });
  if (!parsed) return { ok: false, value: "", error: "Use an HTTP(S) address without credentials, query or fragment." };
  if (/%(?:2e|2f|5c)/i.test(parsed.path) || /(^|\/)\.\.?($|\/)/.test(parsed.path)) {
    return { ok: false, value: "", error: "The Homepage base path contains an unsafe path segment." };
  }
  let path = parsed.path.replace(/\/+$/, "");
  if (path === "/") path = "";
  return { ok: true, value: parsed.scheme + "://" + parsed.authority.host +
    (parsed.authority.port ? ":" + String(Number(parsed.authority.port)) : "") + path, error: "" };
}

function originUrl(raw) {
  const normalized = normalizeBaseUrl(raw);
  if (!normalized.ok) return "";
  const parsed = parseHttpUrl(normalized.value, { maxLength: 2048, originOnly: false });
  if (!parsed) return "";
  return parsed.scheme + "://" + parsed.authority.host +
    (parsed.authority.port ? ":" + String(Number(parsed.authority.port)) : "");
}

function effectiveCaCertPath(baseUrl, caCertPath, trustOrigin) {
  const path = String(caCertPath || "").trim();
  const origin = originUrl(baseUrl);
  return path && origin && String(trustOrigin || "").trim().toLowerCase() === origin ? path : "";
}

function normalizeMcpPath(raw) {
  const value = typeof raw === "string" ? raw.trim() : "";
  if (!value || value.length > 256 || value.charAt(0) !== "/" || value.indexOf("//") === 0 || /[?#\\\s\u0000-\u001f\u007f]/.test(value)) return "";
  if (/%(?![0-9a-f]{2})/i.test(value) || /(?:^|\/)\.\.?(?:\/|$)/.test(value) || /%(?:2e|2f|5c)/i.test(value)) return "";
  return value;
}

function byteLengthOf(value) {
  if (typeof TextEncoder !== "undefined") return new TextEncoder().encode(value).length;
  return unescape(encodeURIComponent(value)).length;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function serviceFields(raw, groupName) {
  if (!isObject(raw)) return null;
  const name = cleanText(raw.name, LIMITS.name);
  if (!name) return null;
  const href = safeHttpUrl(raw.href, LIMITS.href);
  const hasDockerLink = Boolean(cleanText(raw.server, LIMITS.metadata) || cleanText(raw.container, LIMITS.metadata));
  return {
    name,
    href,
    linkAvailable: Boolean(href),
    icon: cleanText(raw.icon, LIMITS.icon),
    description: cleanText(raw.description, LIMITS.description),
    server: cleanText(raw.server, LIMITS.metadata),
    container: cleanText(raw.container, LIMITS.metadata),
    ping: cleanText(raw.ping, LIMITS.metadata),
    weight: typeof raw.weight === "number" && isFinite(raw.weight) ? raw.weight : cleanText(raw.weight, 32),
    group: groupName,
    dockerLinked: hasDockerLink,
    // Homepage's services endpoint does not provide a reliable live health state.
    status: ""
  };
}

function parseServices(payload, byteLength) {
  if (Number.isFinite(byteLength) && byteLength > LIMITS.responseBytes) return { ok: false, error: "Response exceeds the size limit", groups: [], services: [] };
  if (typeof payload !== "string" || byteLengthOf(payload) > LIMITS.responseBytes) return { ok: false, error: "Response exceeds the size limit", groups: [], services: [] };
  let source;
  try { source = JSON.parse(payload); } catch (_) { return { ok: false, error: "Invalid JSON response", groups: [], services: [] }; }
  if (!Array.isArray(source)) return { ok: false, error: "Expected a Homepage group list", groups: [], services: [] };

  let groupCount = 0;
  const services = [];
  function walk(rawGroups, parents, depth) {
    const output = [];
    if (!Array.isArray(rawGroups) || depth > LIMITS.depth || groupCount >= LIMITS.groups) return output;
    for (const raw of rawGroups) {
      if (!isObject(raw) || groupCount >= LIMITS.groups) continue;
      let name = cleanText(raw.name || raw.group, LIMITS.groupName);
      let entries = Array.isArray(raw.services) ? raw.services : null;
      let children = Array.isArray(raw.groups) ? raw.groups : [];
      if (!name) {
        const keys = Object.keys(raw);
        for (const key of keys) {
          if (["type", "name", "group", "services", "groups"].indexOf(key) !== -1) continue;
          if (Array.isArray(raw[key])) { name = cleanText(key, LIMITS.groupName); entries = raw[key]; break; }
        }
      }
      if (!name) continue;
      const path = parents.length ? parents.join(" / ") + " / " + name : name;
      const group = { name, path, services: [], groups: [] };
      groupCount++;
      if (entries) {
        for (const rawService of entries) {
          if (services.length >= LIMITS.services) break;
          let candidate = rawService;
          if (isObject(candidate) && typeof candidate.name !== "string") {
            const keys = Object.keys(candidate);
            const key = keys.find(item => isObject(candidate[item]));
            if (key) {
              const normalized = {};
              const fields = Object.keys(candidate[key]);
              for (let fieldIndex = 0; fieldIndex < fields.length; ++fieldIndex) normalized[fields[fieldIndex]] = candidate[key][fields[fieldIndex]];
              normalized.name = key;
              candidate = normalized;
            }
          }
          const service = serviceFields(candidate, path);
          if (service) { group.services.push(service); services.push(service); }
        }
      }
      if (children.length) group.groups = walk(children, parents.concat([name]), depth + 1);
      output.push(group);
    }
    return output;
  }
  const groups = walk(source, [], 0);
  return { ok: true, error: "", groups, services };
}

function filterGroups(groups, query) {
  const needle = cleanText(query, 200).toLocaleLowerCase();
  if (!needle) return groups;
  const result = [];
  for (const group of groups || []) {
    const groupMatches = (group.path || group.name).toLocaleLowerCase().includes(needle);
    const matchedServices = groupMatches ? group.services : group.services.filter(service =>
      service.name.toLocaleLowerCase().includes(needle) || service.description.toLocaleLowerCase().includes(needle));
    const children = filterGroups(group.groups, needle);
    // Search results only include groups that lead to at least one service.
    if (matchedServices.length || children.length) {
      result.push({ name: group.name, path: group.path, services: matchedServices, groups: children });
    }
  }
  return result;
}

function countGroups(groups) {
  let count = 0;
  for (const group of groups || []) count += 1 + countGroups(group.groups);
  return count;
}

function countServices(groups) {
  let count = 0;
  for (const group of groups || []) count += (group.services || []).length + countServices(group.groups);
  return count;
}

function displayRows(groups, searching, expandedOverrides, rows, depth) {
  const output = rows || [];
  const currentDepth = depth || 0;
  const overrides = expandedOverrides || {};
  for (const group of groups || []) {
    const serviceCount = countServices([group]);
    const isExpanded = searching || Object.prototype.hasOwnProperty.call(overrides, group.path)
      ? searching || overrides[group.path] === true
      : serviceCount <= 4;
    output.push({
      type: "group",
      name: group.name,
      path: group.path,
      count: serviceCount,
      depth: currentDepth,
      expanded: isExpanded,
      expandable: serviceCount > 0
    });
    if (!isExpanded) continue;
    for (const service of group.services || []) {
      output.push({ type: "service", service, depth: currentDepth + 1 });
    }
    displayRows(group.groups, searching, overrides, output, currentDepth + 1);
  }
  return output;
}

function flattenGroups(groups, result) {
  const output = result || [];
  for (const group of groups || []) {
    output.push({ name: group.name, path: group.path || group.name, services: group.services || [] });
    flattenGroups(group.groups, output);
  }
  return output;
}

function clampSeconds(value, fallback, min, max) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(min, Math.min(max, Math.floor(number))) : fallback;
}

function statusAfterFailure(hasCachedData, ageSeconds, staleSeconds) {
  if (!hasCachedData) return "ERROR";
  return ageSeconds > clampSeconds(staleSeconds, 300, 30, 86400) ? "STALE" : "OFFLINE";
}

function apiState(status, exitCode, hasCachedData, ageSeconds, staleSeconds) {
  if (exitCode !== 0) return statusAfterFailure(hasCachedData, ageSeconds, staleSeconds);
  if (status === 401 || status === 403 || (status >= 300 && status < 400)) return "AUTH REQUIRED";
  if (status === 200) return "ONLINE";
  return hasCachedData ? statusAfterFailure(true, ageSeconds, staleSeconds) : "ERROR";
}

function tlsTrustStatus(mode) {
  switch (String(mode || "system")) {
    case "custom-ca": return "CUSTOM CA";
    case "self-signed": return "SELF-SIGNED TRUST";
    default: return "SYSTEM TRUST";
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    LIMITS,
    cleanText,
    parseHttpUrl,
    safeHttpUrl,
    normalizeBaseUrl,
    originUrl,
    effectiveCaCertPath,
    normalizeMcpPath,
    parseServices,
    filterGroups,
    countGroups,
    countServices,
    displayRows,
    flattenGroups,
    clampSeconds,
    statusAfterFailure,
    apiState,
    tlsTrustStatus
  };
}
