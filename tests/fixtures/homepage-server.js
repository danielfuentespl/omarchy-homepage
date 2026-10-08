"use strict";

const http = require("node:http");

const TOOLS = ["list_config_files", "read_config_file", "validate_config_file", "write_config_file", "add_service"];

function createHomepageServer(options = {}) {
  const state = {
    yaml: options.yaml || "- Infrastructure:\n    - Proxmox:\n        href: https://pve.example.test\n",
    calls: [],
    authorizedRequests: 0,
    writeCount: 0
  };

  const handleRequest = async (request, response) => {
    if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
    if (request.url === "/api/services") {
      if (options.delayServicesMs) await new Promise(resolve => setTimeout(resolve, options.delayServicesMs));
      if (options.servicesRedirect) { response.writeHead(302, { location: "/redirect-target" }); response.end("redirect"); return; }
      const status = options.servicesStatus || 200;
      response.writeHead(status, { "content-type": "application/json" });
      response.end(options.servicesBody !== undefined ? options.servicesBody : JSON.stringify([
        { name: "Infrastructure", type: "group", services: [{ name: "Proxmox", href: "https://pve.example.test" }], groups: [] }
      ]));
      return;
    }
    if (request.url !== "/api/mcp" || request.method !== "POST") {
      response.writeHead(404, { "content-type": "application/json" }); response.end("{}"); return;
    }
    if (options.mcpDelayMs) await new Promise(resolve => setTimeout(resolve, options.mcpDelayMs));
    if (options.mcpRedirect) { response.writeHead(options.mcpRedirect, { location: "/mcp-target" }); response.end("redirect"); return; }
    if (options.mcpStatus) { response.writeHead(options.mcpStatus, { "content-type": "application/json" }); response.end("{}"); return; }
    const expected = options.token || "a".repeat(40);
    if (request.headers.authorization !== "Bearer " + expected) {
      response.writeHead(401, { "content-type": "application/json" }); response.end("{}"); return;
    }
    state.authorizedRequests++;
    let body = "";
    for await (const chunk of request) body += chunk;
    let rpc;
    try { rpc = JSON.parse(body); } catch (_) {
      response.writeHead(400, { "content-type": "application/json" }); response.end("{}"); return;
    }
    if (options.mcpBody !== undefined) {
      response.writeHead(200, { "content-type": "application/json" }); response.end(options.mcpBody); return;
    }
    const method = rpc.method;
    const params = rpc.params || {};
    state.calls.push({ method, name: params.name || "", arguments: params.arguments || {} });
    let result;
    if (method === "tools/list") {
      result = { tools: TOOLS.map(name => ({ name })) };
    } else if (method === "tools/call") {
      result = callTool(state, params.name, params.arguments || {}, options);
    } else {
      response.writeHead(200, { "content-type": "application/json" });
      response.end("not-json"); return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    const responseObject = options.mcpMissingResult ? { jsonrpc: "2.0", id: rpc.id }
      : { jsonrpc: "2.0", id: rpc.id + (options.mcpWrongId ? 1 : 0), result };
    response.end(JSON.stringify(responseObject));
  };
  const server = http.createServer((request, response) => {
    handleRequest(request, response).catch(() => {
      if (!response.headersSent) response.writeHead(500, { "content-type": "application/json" });
      response.end("{}");
    });
  });

  return { server, state, handleRequest };
}

function textResult(value, isError = false) {
  return { isError, content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) }] };
}

function callTool(state, name, args, options) {
  if (name === "list_config_files") return textResult({ files: [{ file: "services.yaml", writable: options.writable !== false }] });
  if (name === "read_config_file" && args.file === "services.yaml") {
    let content = state.yaml;
    if (options.corruptReadback && state.writeCount > 0) content += "# corrupted read-back\n";
    return textResult(content);
  }
  if (name === "validate_config_file" && args.file === "services.yaml") {
    if (typeof args.content !== "string" || args.content.includes("INVALID_YAML")) {
      return textResult({ valid: false, error: "Invalid YAML fixture", mark: { line: 2, column: 3 } }, true);
    }
    return textResult({ valid: true });
  }
  if (name === "write_config_file" && args.file === "services.yaml") {
    if (options.writable === false) return textResult({ error: "writes disabled" }, true);
    state.yaml = args.content;
    state.writeCount++;
    return textResult({ written: "services.yaml" });
  }
  if (name === "add_service") {
    state.yaml += `\n- ${args.group}:\n    - ${args.name}:\n        href: ${args.service.href}\n`;
    state.writeCount++;
    return textResult({ written: "services.yaml", added: { group: args.group, service: args.name }, content: state.yaml });
  }
  return textResult({ error: "unknown tool" }, true);
}

module.exports = { createHomepageServer };
