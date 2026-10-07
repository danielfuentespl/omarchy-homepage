"use strict";

const SERVICES_PATH = "/api/services";

function servicesUrl(baseUrl, normalizeBaseUrl, originUrl) {
  const normalized = normalizeBaseUrl(baseUrl);
  if (!normalized.ok) return { ok: false, error: normalized.error, baseUrl: "", url: "" };
  const origin = originUrl(baseUrl);
  if (!origin) return { ok: false, error: "Enter a valid Homepage HTTP(S) address.", baseUrl: "", url: "" };
  return { ok: true, error: "", baseUrl: normalized.value, url: origin + SERVICES_PATH };
}

function parseServicesResponse(contentType, body, parseServices) {
  const type = typeof contentType === "string" ? contentType.toLowerCase() : "";
  if (type !== "application/json" && !type.endsWith("+json")) {
    return { ok: false, error: "Homepage returned a non-JSON response.", groups: [], services: [] };
  }
  return parseServices(body);
}

if (typeof module !== "undefined") module.exports = { SERVICES_PATH, servicesUrl, parseServicesResponse };
