"use strict";

function quote(value) {
  const text = String(value);
  if (text.indexOf("\u0000") !== -1 || /[\r\n]/.test(text)) throw new Error("Invalid curl configuration value");
  return '"' + text.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\t/g, "\\t") + '"';
}

function line(option, value) {
  if (!/^[a-z][a-z-]*$/.test(option)) throw new Error("Invalid curl option");
  return option + " = " + quote(value);
}

function curlArguments() { return ["-q", "--config", "-"]; }

function buildRequest(spec, marker) {
  if (!spec || (spec.method !== "GET" && spec.method !== "POST")) return { ok: false, error: "Unsupported HTTP method" };
  if (typeof spec.url !== "string" || !/^https?:\/\//i.test(spec.url) || /[\s\\\u0000-\u001f\u007f]/.test(spec.url)) {
    return { ok: false, error: "Invalid request URL" };
  }
  if (typeof marker !== "string" || !/^OMAHP_[A-Za-z0-9_.=-]{1,120}$/.test(marker)) return { ok: false, error: "Invalid response marker" };
  const timeout = Math.max(1, Math.min(30, Math.floor(Number(spec.timeoutSec) || 8)));
  const maxBytes = Math.max(1024, Math.min(1024 * 1024, Math.floor(Number(spec.maxBytes) || 512 * 1024)));
  const lines = [
    "silent",
    "show-error",
    line("url", spec.url),
    line("request", spec.method),
    line("connect-timeout", String(Math.min(timeout, 5))),
    line("max-time", String(timeout)),
    line("max-filesize", String(maxBytes)),
    line("header", "Accept: application/json")
  ];
  if (spec.method === "POST") {
    lines.push(line("header", "Content-Type: application/json"));
    if (spec.token) {
      if (typeof spec.token !== "string" || spec.token.length < 32 || !/^[A-Za-z0-9_+/=-]+$/.test(spec.token)) {
        return { ok: false, error: "MCP token is invalid" };
      }
      if (!/^https:\/\//i.test(spec.url)) return { ok: false, error: "MCP credentials require HTTPS" };
      lines.push(line("header", "Authorization: Bearer " + spec.token));
    }
    lines.push(line("data-binary", typeof spec.body === "string" ? spec.body : "{}"));
  } else if (spec.token) return { ok: false, error: "Credentials are only allowed for MCP POST requests" };
  if (spec.caCertPath) {
    if (typeof spec.caCertPath !== "string" || spec.caCertPath.charAt(0) !== "/" || /[\r\n\u0000]/.test(spec.caCertPath)) {
      return { ok: false, error: "CA certificate path must be absolute" };
    }
    lines.push(line("cacert", spec.caCertPath));
  }
  // No location/redirect option is ever enabled. Status and content metadata
  // go to stderr so stdout contains only the response body.
  lines.push(line("write-out", "%{stderr}" + marker + "=%{http_code}|%{content_type}|%{size_download}|%{redirect_url}"));
  return { ok: true, text: lines.join("\n") + "\n" };
}

function parseOutput(stdout, stderr, marker) {
  const text = String(stderr || "");
  const position = text.lastIndexOf(marker + "=");
  if (position < 0) return { ok: false, error: "HTTP response metadata is missing" };
  const record = text.slice(position + marker.length + 1).replace(/[\r\n]+$/, "");
  const match = /^(\d{3})\|([^|]*)\|([0-9]+(?:\.[0-9]+)?)\|(.*)$/.exec(record);
  if (!match) return { ok: false, error: "HTTP response metadata is invalid" };
  const body = String(stdout || "");
  const bytes = Number(match[3]);
  return {
    ok: bytes <= 1024 * 1024,
    status: Number(match[1]),
    contentType: match[2].split(";")[0].trim().toLowerCase(),
    bytes,
    redirectUrl: match[4],
    body,
    error: bytes > 1024 * 1024 ? "Response exceeds the size limit" : ""
  };
}

function errorKind(code) {
  if (code === 6 || code === 7 || code === 28) return "network";
  if (code === 60 || code === 77 || [35, 51, 58, 59, 64, 66, 80, 82, 83, 90, 91].indexOf(code) !== -1) return "tls";
  if (code === 127 || code === -2) return "missing-curl";
  return "transport";
}

if (typeof module !== "undefined") module.exports = { quote, line, curlArguments, buildRequest, parseOutput, errorKind };
