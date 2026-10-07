"use strict";

function rpcRequest(id, method, params) {
  if (!Number.isSafeInteger(id) || id < 1 || typeof method !== "string" || !method) return null;
  const request = { jsonrpc: "2.0", id, method };
  if (params !== undefined) request.params = params;
  return request;
}

function parseRpcResponse(payload, expectedId) {
  let value;
  try { value = typeof payload === "string" ? JSON.parse(payload) : payload; }
  catch (_) { return { ok: false, error: "MCP returned invalid JSON." }; }
  if (!value || typeof value !== "object" || value.jsonrpc !== "2.0" || value.id !== expectedId) {
    return { ok: false, error: "MCP returned an invalid JSON-RPC response." };
  }
  if (value.error && typeof value.error === "object") {
    return { ok: false, code: value.error.code, error: typeof value.error.message === "string" ? value.error.message : "MCP request failed." };
  }
  if (!Object.prototype.hasOwnProperty.call(value, "result")) return { ok: false, error: "MCP response has no result." };
  return { ok: true, result: value.result };
}

function textFromToolResult(result) {
  if (!result || typeof result !== "object" || !Array.isArray(result.content)) return { ok: false, error: "MCP tool returned no content." };
  const text = result.content.filter(item => item && item.type === "text" && typeof item.text === "string").map(item => item.text).join("\n");
  if (result.isError === true) return { ok: false, error: text || "Homepage rejected the MCP operation." };
  return { ok: true, text };
}

function parseTools(result) {
  if (!result || typeof result !== "object" || !Array.isArray(result.tools)) return { ok: false, error: "MCP tools/list response is malformed." };
  const names = [];
  for (const tool of result.tools) if (tool && typeof tool.name === "string") names.push(tool.name);
  return { ok: true, names };
}

function parseWritableConfigFiles(toolResult) {
  const content = textFromToolResult(toolResult);
  if (!content.ok) return content;
  let value;
  try { value = JSON.parse(content.text); } catch (_) { return { ok: false, error: "MCP config-file status is malformed." }; }
  if (!value || !Array.isArray(value.files)) return { ok: false, error: "MCP config-file status is malformed." };
  const services = value.files.find(file => file && file.file === "services.yaml");
  if (!services) return { ok: false, error: "Homepage MCP does not expose services.yaml." };
  return { ok: true, writable: services.writable === true };
}

function parseValidation(toolResult) {
  const content = textFromToolResult(toolResult);
  if (!content.ok) {
    // Homepage reports invalid YAML as an isError text result containing
    // validation details. Keep the server's message visible to the user.
    try {
      const result = JSON.parse(content.error);
      return { ok: true, valid: result.valid === true, error: result.error || "YAML validation failed.", mark: result.mark || null };
    } catch (_) { return { ok: true, valid: false, error: content.error, mark: null }; }
  }
  let value;
  try { value = JSON.parse(content.text); } catch (_) { return { ok: false, error: "MCP YAML validation response is malformed." }; }
  if (!value || typeof value.valid !== "boolean") return { ok: false, error: "MCP YAML validation response is malformed." };
  return { ok: true, valid: value.valid, error: value.error || "", mark: value.mark || null };
}

function parseAddService(toolResult) {
  const content = textFromToolResult(toolResult);
  if (!content.ok) return content;
  let value;
  try { value = JSON.parse(content.text); } catch (_) { return { ok: false, error: "Homepage add_service response is malformed." }; }
  if (!value || !value.written || !value.added || value.written !== "services.yaml" || typeof value.content !== "string") {
    return { ok: false, error: "Homepage did not confirm the service write." };
  }
  return { ok: true, content: value.content, group: value.added.group, name: value.added.service };
}

function makeToolCall(id, name, args) {
  const allowed = ["list_config_files", "read_config_file", "validate_config_file", "write_config_file", "add_service"];
  if (allowed.indexOf(name) === -1) return null;
  return rpcRequest(id, "tools/call", { name, arguments: args || {} });
}

if (typeof module !== "undefined") {
  module.exports = { rpcRequest, parseRpcResponse, textFromToolResult, parseTools,
    parseWritableConfigFiles, parseValidation, parseAddService, makeToolCall };
}
