"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const Mcp = require("../McpClient.js");

test("builds and validates JSON-RPC requests and exact response identities", () => {
  assert.deepEqual(Mcp.rpcRequest(3, "tools/list", {}), { jsonrpc: "2.0", id: 3, method: "tools/list", params: {} });
  assert.equal(Mcp.rpcRequest(0, "tools/list", {}), null);
  assert.equal(Mcp.parseRpcResponse('{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}', 3).ok, true);
  assert.equal(Mcp.parseRpcResponse('{"jsonrpc":"2.0","id":4,"result":{}}', 3).ok, false);
  assert.equal(Mcp.parseRpcResponse('{bad', 3).ok, false);
  assert.equal(Mcp.parseRpcResponse({ jsonrpc: "2.0", id: 3, error: { code: -32601, message: "secret YAML content" } }, 3).error,
    "MCP server rejected the requested operation.");
});

test("read-only tool allowlist permits only services.yaml and rejects all other calls locally", () => {
  assert.deepEqual(Mcp.makeToolCall(1, "read_config_file", { file: "services.yaml" }), {
    jsonrpc: "2.0", id: 1, method: "tools/call",
    params: { name: "read_config_file", arguments: { file: "services.yaml" } }
  });
  for (const file of ["settings.yaml", "widgets.yaml", "bookmarks.yaml", "docker.yaml", "kubernetes.yaml",
    "proxmox.yaml", "custom.js", "custom.css", "../services.yaml"]) {
    assert.equal(Mcp.makeToolCall(2, "read_config_file", { file }), null);
  }
  assert.equal(Mcp.makeToolCall(2, "read_config_file", { file: "services.yaml", content: "ignored" }), null);
  for (const name of ["list_config_files", "validate_config_file", "write_config_file", "add_service", "add_info_widget", "homepage_docs", "execute_shell"]) {
    assert.equal(Mcp.makeToolCall(3, name, {}), null, name + " must not be callable in read-only phase");
  }
  assert.deepEqual(Mcp.parseTools({ tools: [{ name: "add_service" }, { name: "write_config_file" }, { name: "read_config_file" }] }), {
    ok: true, names: ["add_service", "write_config_file", "read_config_file"]
  });
  assert.deepEqual(Mcp.capabilitySummary(["read_config_file", "validate_config_file", "add_service", "write_config_file"]),
    ["read_config_file", "validate_config_file", "add_service", "write_config_file"]);
  assert.equal(Mcp.supportsTool(["read_config_file"], "read_config_file"), true);
  assert.equal(Mcp.supportsTool(["read_config_file"], "write_config_file"), false);
});

test("MCP configuration identity changes for generation, origin, token ID and every TLS trust mode", () => {
  const base = { generation: 1, baseUrl: "https://homepage.example", origin: "https://homepage.example",
    secretId: "default", caCertPath: "", tlsTrustMode: "system", tlsTrustOrigin: "", tlsTrustFingerprint: "", mcpPath: "/api/mcp" };
  const key = Mcp.configurationKey(base);
  for (const [name, value] of Object.entries({ generation: 2, origin: "https://other.example", secretId: "alternate",
    caCertPath: "/tmp/example-ca.pem", tlsTrustMode: "private-ca", tlsTrustOrigin: "https://homepage.example",
    tlsTrustFingerprint: "aa:bb", mcpPath: "/custom/mcp" })) {
    assert.notEqual(Mcp.configurationKey({ ...base, [name]: value }), key, name + " must invalidate an MCP session");
  }
});

test("MCP error tool content is never copied into an error message", () => {
  const secretYaml = "apiKey: super-secret-value";
  const result = Mcp.textFromToolResult({ isError: true, content: [{ type: "text", text: secretYaml }] });
  assert.equal(result.ok, false);
  assert.equal(result.error.includes(secretYaml), false);
});

test("detects read-only versus writable services.yaml capability", () => {
  const readonly = { content: [{ type: "text", text: JSON.stringify({ files: [{ file: "services.yaml", writable: false }] }) }] };
  const writable = { content: [{ type: "text", text: JSON.stringify({ files: [{ file: "services.yaml", writable: true }] }) }] };
  assert.deepEqual(Mcp.parseWritableConfigFiles(readonly), { ok: true, writable: false });
  assert.deepEqual(Mcp.parseWritableConfigFiles(writable), { ok: true, writable: true });
  assert.equal(Mcp.parseWritableConfigFiles({ content: [] }).ok, false);
});

test("parses YAML validation errors and valid responses", () => {
  const invalid = { isError: true, content: [{ type: "text", text: JSON.stringify({ valid: false, error: "bad indentation", mark: { line: 3, column: 4 } }) }] };
  const valid = { content: [{ type: "text", text: JSON.stringify({ valid: true }) }] };
  assert.deepEqual(Mcp.parseValidation(invalid), { ok: true, valid: false,
    error: "Homepage rejected the requested MCP operation.", mark: null });
  assert.deepEqual(Mcp.parseValidation(valid), { ok: true, valid: true, error: "", mark: null });
});

test("requires add_service to confirm its YAML result for a later read-back", () => {
  const added = { content: [{ type: "text", text: JSON.stringify({ written: "services.yaml", added: { group: "Media", service: "Jellyfin" }, content: "- Media:\n    - Jellyfin:\n        href: https://jellyfin.example.test\n" }) }] };
  const result = Mcp.parseAddService(added);
  assert.equal(result.ok, true);
  assert.equal(result.group, "Media");
  assert.equal(result.name, "Jellyfin");
  assert.equal(Mcp.parseAddService({ content: [{ type: "text", text: "not json" }] }).ok, false);
});

test("stops the YAML workflow when its configuration generation becomes stale before write", async () => {
  let generation = 1;
  const calls = [];
  const callTool = (name, args, callback) => {
    if (generation !== 1) {
      callback({ ok: false, requestStarted: false, error: "Homepage MCP configuration changed; stale operation rejected." });
      return;
    }
    calls.push(name);
    if (name === "validate_config_file") {
      generation++;
      callback({ ok: true, result: { content: [{ type: "text", text: JSON.stringify({ valid: true }) }] } });
      return;
    }
    callback({ ok: true, result: { content: [{ type: "text", text: JSON.stringify({ written: "services.yaml" }) }] } });
  };
  const result = await new Promise(resolve => Mcp.writeAndVerifyServicesYaml(callTool, "- Test:\n", resolve));
  assert.equal(result.ok, false);
  assert.match(result.error, /stale operation rejected/);
  assert.equal(result.writeMayHaveChanged, undefined);
  assert.deepEqual(calls, ["validate_config_file"], "no stale write request should be sent");
});

test("flags an interrupted write or add request as potentially changed", async () => {
  const validation = { ok: true, result: { content: [{ type: "text", text: JSON.stringify({ valid: true }) }] } };
  const interrupted = { ok: false, requestStarted: true, error: "request cancelled" };
  const writeResult = await new Promise(resolve => {
    Mcp.writeAndVerifyServicesYaml((name, args, callback) => callback(name === "validate_config_file" ? validation : interrupted), "- Test:\n", resolve);
  });
  assert.equal(writeResult.writeMayHaveChanged, true);
  assert.equal(writeResult.error, "request cancelled");

  const addResult = await new Promise(resolve => Mcp.addAndVerifyService((_name, _args, callback) => callback(interrupted), {}, resolve));
  assert.equal(addResult.writeMayHaveChanged, true);
  assert.equal(addResult.error, "request cancelled");
});
