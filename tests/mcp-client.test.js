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

test("MCP tool allowlist restricts read, validation and restoration to services.yaml", () => {
  assert.deepEqual(Mcp.makeToolCall(1, "read_config_file", { file: "services.yaml" }), {
    jsonrpc: "2.0", id: 1, method: "tools/call",
    params: { name: "read_config_file", arguments: { file: "services.yaml" } }
  });
  for (const file of ["settings.yaml", "widgets.yaml", "bookmarks.yaml", "docker.yaml", "kubernetes.yaml",
    "proxmox.yaml", "custom.js", "custom.css", "../services.yaml"]) {
    assert.equal(Mcp.makeToolCall(2, "read_config_file", { file }), null);
  }
  assert.equal(Mcp.makeToolCall(2, "read_config_file", { file: "services.yaml", content: "ignored" }), null);
  assert.deepEqual(Mcp.makeToolCall(3, "list_config_files", {}), {
    jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_config_files", arguments: {} }
  });
  for (const name of ["add_info_widget", "homepage_docs", "execute_shell"]) assert.equal(Mcp.makeToolCall(3, name, {}), null, name);
  assert.equal(Mcp.makeToolCall(3, "validate_config_file", { file: "widgets.yaml", content: "x" }), null);
  assert.equal(Mcp.makeToolCall(3, "write_config_file", { file: "widgets.yaml", content: "x" }), null);
  assert.deepEqual(Mcp.parseTools({ tools: [{ name: "add_service" }, { name: "write_config_file" }, { name: "read_config_file" }] }), {
    ok: true, names: ["add_service", "write_config_file", "read_config_file"]
  });
  assert.deepEqual(Mcp.capabilitySummary(["read_config_file", "validate_config_file", "add_service", "write_config_file"]),
    ["read_config_file", "validate_config_file", "add_service", "write_config_file"]);
  assert.equal(Mcp.supportsTool(["read_config_file"], "read_config_file"), true);
  assert.equal(Mcp.supportsTool(["read_config_file"], "write_config_file"), false);
});

test("both independent write gates are required and a busy add blocks duplicate submits", () => {
  assert.equal(Mcp.writeGatesOpen(false, true, true), false, "server gate is mandatory");
  assert.equal(Mcp.writeGatesOpen(true, false, true), false, "local gate is mandatory");
  assert.equal(Mcp.writeGatesOpen(true, true, false), false, "authenticated MCP is mandatory");
  assert.equal(Mcp.writeGatesOpen(true, true, true), true);
  assert.equal(Mcp.canStartWrite(true, true, true, false), true);
  assert.equal(Mcp.canStartWrite(true, true, true, true), false);
});

test("add_service accepts only the simple safe v0.1 service payload", () => {
  const args = { group: "Demo Group", name: "Demo Service", service: {
    href: "https://service.example.invalid/demo", description: "Fictional service used in a unit test"
  } };
  const built = Mcp.makeToolCall(4, "add_service", args);
  assert.equal(built.params.name, "add_service");
  assert.deepEqual(built.params.arguments, args);
  for (const href of ["javascript:alert(1)", "file:///etc/passwd", "http://user:pass@example.invalid", "//example.invalid/path"]) {
    assert.equal(Mcp.makeToolCall(5, "add_service", { ...args, service: { href } }), null, href);
  }
  assert.equal(Mcp.makeToolCall(5, "add_service", { ...args, service: { ...args.service, server: "docker" } }), null);
  assert.equal(Mcp.makeToolCall(5, "add_service", { ...args, service: { ...args.service, container: "homepage" } }), null);
  assert.equal(Mcp.makeToolCall(5, "add_service", { ...args, apiKey: "secret" }), null);
  assert.equal(Mcp.makeToolCall(5, "add_info_widget", args), null);
});

test("MCP configuration identity changes for generation, origin, token ID and every TLS trust mode", () => {
  const base = { generation: 1, baseUrl: "https://homepage.example", origin: "https://homepage.example",
    secretId: "default", caCertPath: "", tlsTrustMode: "system", tlsTrustOrigin: "", tlsTrustFingerprint: "", mcpPath: "/api/mcp" };
  const key = Mcp.configurationKey(base);
  for (const [name, value] of Object.entries({ generation: 2, origin: "https://other.example", secretId: "alternate",
    caCertPath: "/tmp/example-ca.pem", tlsTrustMode: "private-ca", tlsTrustOrigin: "https://homepage.example",
    tlsTrustFingerprint: "aa:bb", mcpPath: "/custom/mcp", editingEnabled: true })) {
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

test("stops add when configuration generation becomes stale after the initial read", async () => {
  let generation = 1;
  const calls = [];
  const callTool = (name, args, callback) => {
    if (generation !== 1) {
      callback({ ok: false, requestStarted: false, error: "Homepage MCP configuration changed; stale operation rejected." });
      return;
    }
    calls.push(name);
    if (name === "read_config_file") {
      generation++;
      callback({ ok: true, result: { content: [{ type: "text", text: "original\n" }] } });
      return;
    }
    callback({ ok: false, requestStarted: false, error: "Homepage MCP configuration changed; stale operation rejected." });
  };
  const result = await new Promise(resolve => Mcp.addAndVerifyService(callTool,
    { group: "Test", name: "New", service: { href: "https://example.invalid" } }, resolve));
  assert.equal(result.ok, false);
  assert.match(result.error, /stale operation rejected/);
  assert.equal(result.writeMayHaveChanged, undefined);
  assert.deepEqual(calls, ["read_config_file"], "stale add call is rejected before dispatch");
});

test("configuration change during add prevents its stale response from continuing the sequence", async () => {
  let currentGeneration = 1;
  const calls = [];
  const result = await new Promise(resolve => Mcp.addAndVerifyService((name, _args, callback) => {
    if (currentGeneration !== 1) {
      callback({ ok: false, requestStarted: false, error: "stale configuration" });
      return;
    }
    calls.push(name);
    if (name === "read_config_file") callback({ ok: true, result: { content: [{ type: "text", text: "original\n" }] } });
    else {
      currentGeneration++;
      callback({ ok: false, requestStarted: true, error: "configuration changed while write was in flight" });
    }
  }, { group: "Test", name: "New", service: { href: "https://example.invalid" } }, resolve));
  assert.equal(result.writeMayHaveChanged, true);
  assert.match(result.error, /WRITE OUTCOME UNKNOWN/);
  assert.deepEqual(calls, ["read_config_file", "add_service"], "stale operation must not continue to read back under an old configuration");
});

test("an interrupted write is ambiguous and an add gets read-back without retry", async () => {
  const interrupted = { ok: false, requestStarted: true, error: "request cancelled" };
  const calls = [];
  const addResult = await new Promise(resolve => Mcp.addAndVerifyService((name, _args, callback) => {
    calls.push(name);
    if (name === "read_config_file") callback({ ok: true, result: { content: [{ type: "text", text: calls.length === 1 ? "before\n" : "after\n" }] } });
    else callback(interrupted);
  }, { group: "Test", name: "Test", service: { href: "https://example.invalid" } }, resolve));
  assert.equal(addResult.writeMayHaveChanged, true);
  assert.match(addResult.error, /WRITE OUTCOME UNKNOWN/);
  assert.deepEqual(calls, ["read_config_file", "add_service", "read_config_file"], "ambiguous write gets read-back, never a second write");
});

test("add success requires read-back and exact agreement with server response", async () => {
  const before = "# existing\n";
  const after = before + "- Test:\n    - Example:\n        href: https://example.invalid\n";
  const names = [];
  const result = await new Promise(resolve => Mcp.addAndVerifyService((name, _args, callback) => {
    names.push(name);
    if (name === "read_config_file") callback({ ok: true, result: { content: [{ type: "text", text: names.length === 1 ? before : after }] } });
    else callback({ ok: true, result: { content: [{ type: "text", text: JSON.stringify({ written: "services.yaml", added: { group: "Test", service: "Example" }, content: after }) }] } });
  }, { group: "Test", name: "Example", service: { href: "https://example.invalid" } }, resolve));
  assert.equal(result.ok, true);
  assert.deepEqual(names, ["read_config_file", "add_service", "read_config_file"]);
});

test("read-back mismatch is reported and never triggers an add retry", async () => {
  let addCalls = 0;
  const result = await new Promise(resolve => Mcp.addAndVerifyService((name, _args, callback) => {
    if (name === "read_config_file") callback({ ok: true, result: { content: [{ type: "text", text: "unchanged\n" }] } });
    else { addCalls++; callback({ ok: true, result: { content: [{ type: "text", text: JSON.stringify({ written: "services.yaml", added: { group: "Test", service: "Example" }, content: "different\n" }) }] } }); }
  }, { group: "Test", name: "Example", service: { href: "https://example.invalid" } }, resolve));
  assert.equal(result.ok, false);
  assert.match(result.error, /WRITE OUTCOME UNKNOWN/);
  assert.equal(addCalls, 1);
});

test("rollback writes the exact in-memory original and verifies the restored text", async () => {
  const original = "# preserve comments\n- Group:\n    - Existing:\n        href: https://example.invalid\n";
  const calls = [];
  let readBackText = "";
  const result = await new Promise(resolve => Mcp.restoreExactServicesYaml((name, args, callback) => {
    calls.push(name);
    if (name === "write_config_file") {
      assert.equal(args.file, "services.yaml");
      assert.equal(args.content, original);
      callback({ ok: true });
    } else { readBackText = original; callback({ ok: true, result: { content: [{ type: "text", text: readBackText }] } }); }
  }, original, resolve));
  assert.equal(result.ok, true);
  assert.deepEqual(calls, ["write_config_file", "read_config_file"]);
  const hash = value => require("node:crypto").createHash("sha256").update(value).digest("hex");
  assert.equal(hash(readBackText), hash(original));
});

test("write timeouts are not retried and trigger read-back only", async () => {
  const calls = [];
  const result = await new Promise(resolve => Mcp.restoreExactServicesYaml((name, _args, callback) => {
    calls.push(name);
    if (name === "write_config_file") callback({ ok: false, requestStarted: true, error: "timeout" });
    else callback({ ok: true, result: { content: [{ type: "text", text: "unknown" }] } });
  }, "original", resolve));
  assert.equal(result.ok, false);
  assert.match(result.error, /WRITE OUTCOME UNKNOWN/);
  assert.deepEqual(calls, ["write_config_file", "read_config_file"]);
});
