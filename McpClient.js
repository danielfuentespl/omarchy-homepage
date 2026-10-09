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
    return { ok: false, code: value.error.code, error: "MCP server rejected the requested operation." };
  }
  if (!Object.prototype.hasOwnProperty.call(value, "result")) return { ok: false, error: "MCP response has no result." };
  return { ok: true, result: value.result };
}

function textFromToolResult(result) {
  if (!result || typeof result !== "object" || !Array.isArray(result.content)) return { ok: false, error: "MCP tool returned no content." };
  const text = result.content.filter(item => item && item.type === "text" && typeof item.text === "string").map(item => item.text).join("\n");
  if (result.isError === true) return { ok: false, error: "Homepage rejected the requested MCP operation." };
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

function parseAddService(toolResult, expected) {
  const content = textFromToolResult(toolResult);
  if (!content.ok) return content;
  let value;
  try { value = JSON.parse(content.text); } catch (_) { return { ok: false, error: "Homepage add_service response is malformed." }; }
  if (!value || !value.written || !value.added || value.written !== "services.yaml" || typeof value.content !== "string") {
    return { ok: false, error: "Homepage did not confirm the service write." };
  }
  if (expected && (value.added.group !== expected.group || value.added.service !== expected.name)) {
    return { ok: false, error: "Homepage confirmed a different service than the one requested." };
  }
  return { ok: true, content: value.content, group: value.added.group, name: value.added.service };
}

function safeAddServiceArguments(args, safeHttpUrl) {
  if (!args || typeof args !== "object" || Array.isArray(args) ||
      Object.keys(args).sort().join(",") !== "group,name,service") return null;
  const plain = (value, max, required) => typeof value === "string" && value.length <= max &&
    value.trim() === value && !/[\u0000-\u001f\u007f]/.test(value) && (!required || value.length > 0);
  if (!plain(args.group, 120, true) || !plain(args.name, 160, true) ||
      !args.service || typeof args.service !== "object" || Array.isArray(args.service)) return null;
  const service = args.service;
  if (Object.keys(service).some(key => ["href", "description", "icon"].indexOf(key) === -1) ||
      !plain(service.href, 2048, true) ||
      (service.description !== undefined && !plain(service.description, 500, false)) ||
      (service.icon !== undefined && !plain(service.icon, 160, false))) return null;
  const href = typeof safeHttpUrl === "function" ? safeHttpUrl(service.href, 2048) :
    (/^https?:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?(?:\?[^\s#]*)?(?:#[^\s]*)?$/i.test(service.href) ? service.href : "");
  if (!href) return null;
  const safeService = { href };
  if (service.description !== undefined) safeService.description = service.description;
  if (service.icon !== undefined) safeService.icon = service.icon;
  return { group: args.group, name: args.name, service: safeService };
}

function makeToolCall(id, name, args, safeHttpUrl) {
  if (!args || typeof args !== "object" || Array.isArray(args)) return null;
  if (name === "list_config_files" && Object.keys(args).length === 0)
    return rpcRequest(id, "tools/call", { name, arguments: {} });
  if (name === "read_config_file" && args.file === "services.yaml" && Object.keys(args).length === 1)
    return rpcRequest(id, "tools/call", { name, arguments: { file: "services.yaml" } });
  if (name === "validate_config_file" || name === "write_config_file") {
    if (args.file !== "services.yaml" || typeof args.content !== "string" || args.content.length > 512 * 1024 ||
        Object.keys(args).sort().join(",") !== "content,file") return null;
    return rpcRequest(id, "tools/call", { name, arguments: { file: "services.yaml", content: args.content } });
  }
  if (name === "add_service") {
    const safe = safeAddServiceArguments(args, safeHttpUrl);
    if (!safe) return null;
    return rpcRequest(id, "tools/call", { name, arguments: safe });
  }
  return null;
}

function supportsTool(names, name) {
  return Array.isArray(names) && names.indexOf(name) !== -1;
}

function capabilitySummary(names) {
  const supported = ["read_config_file", "validate_config_file", "add_service", "write_config_file"];
  return supported.filter(name => supportsTool(names, name));
}

function configurationKey(spec) {
  return JSON.stringify([spec.generation, spec.baseUrl, spec.origin, spec.secretId, spec.caCertPath,
    spec.tlsTrustMode, spec.tlsTrustOrigin, spec.tlsTrustFingerprint, spec.mcpPath, spec.editingEnabled === true]);
}

function writeGatesOpen(serverWritable, editingEnabled, authenticated) {
  return serverWritable === true && editingEnabled === true && authenticated === true;
}

function canStartWrite(serverWritable, editingEnabled, authenticated, busy) {
  return writeGatesOpen(serverWritable, editingEnabled, authenticated) && busy !== true;
}

function possibleWriteFailure(result) {
  return { ok: false, error: "WRITE OUTCOME UNKNOWN. Read-back is required before any further action.",
    writeMayHaveChanged: true };
}

function addAndVerifyService(callTool, args, callback) {
  callTool("read_config_file", { file: "services.yaml" }, function(initial) {
    if (!initial.ok) { callback(initial); return; }
    const original = textFromToolResult(initial.result);
    if (!original.ok) { callback(original); return; }
    const readBackAfterUncertainWrite = failure => callTool("read_config_file", { file: "services.yaml" }, function(readback) {
      if (!readback.ok) { callback(possibleWriteFailure(readback)); return; }
      const actual = textFromToolResult(readback.result);
      if (!actual.ok) { callback(possibleWriteFailure(actual)); return; }
      callback(actual.text === original.text
        ? { ok: false, error: "The write was not confirmed; read-back matches the original file.", writeMayHaveChanged: false }
        : possibleWriteFailure(failure));
    });
    callTool("add_service", args, function(response) {
      if (!response.ok) {
        if (response.requestStarted) readBackAfterUncertainWrite(response);
        else callback(response);
        return;
      }
      const added = parseAddService(response.result, args);
      if (!added.ok || added.content === original.text) {
        readBackAfterUncertainWrite(added.ok ? { error: "Homepage returned unchanged YAML." } : added);
        return;
      }
      callTool("read_config_file", { file: "services.yaml" }, function(readback) {
        if (!readback.ok) { callback(possibleWriteFailure(readback)); return; }
        const actual = textFromToolResult(readback.result);
        callback(actual.ok && actual.text === added.content
          ? { ok: true, message: "Service added and verified by read-back.", group: added.group, name: added.name }
          : { ok: false, error: actual.ok ? "WRITE OUTCOME UNKNOWN. Add-service read-back did not match." : actual.error, writeMayHaveChanged: true });
      });
    });
  });
}

function restoreExactServicesYaml(callTool, original, callback) {
  if (typeof original !== "string" || original.length > 512 * 1024) {
    callback({ ok: false, error: "The in-memory services.yaml snapshot is invalid." });
    return;
  }
  callTool("write_config_file", { file: "services.yaml", content: original }, function(write) {
    if (!write.ok) {
      if (!write.requestStarted) { callback(write); return; }
      callTool("read_config_file", { file: "services.yaml" }, function(readback) {
        if (!readback.ok) { callback(possibleWriteFailure(readback)); return; }
        const actual = textFromToolResult(readback.result);
        callback(actual.ok && actual.text === original
          ? { ok: true, message: "Original services.yaml restored and verified byte-for-byte." }
          : possibleWriteFailure(write));
      });
      return;
    }
    callTool("read_config_file", { file: "services.yaml" }, function(readback) {
      if (!readback.ok) { callback(possibleWriteFailure(readback)); return; }
      const actual = textFromToolResult(readback.result);
      callback(actual.ok && actual.text === original
        ? { ok: true, message: "Original services.yaml restored and verified byte-for-byte." }
        : { ok: false, error: "WRITE OUTCOME UNKNOWN. Exact restoration could not be verified.", writeMayHaveChanged: true });
    });
  });
}

if (typeof module !== "undefined") {
  module.exports = { rpcRequest, parseRpcResponse, textFromToolResult, parseTools, supportsTool, capabilitySummary, configurationKey,
    parseWritableConfigFiles, parseValidation, parseAddService, makeToolCall, writeGatesOpen, canStartWrite,
    safeAddServiceArguments, addAndVerifyService, restoreExactServicesYaml, possibleWriteFailure };
}
