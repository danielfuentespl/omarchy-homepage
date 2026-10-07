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
  assert.equal(Mcp.parseRpcResponse({ jsonrpc: "2.0", id: 3, error: { code: -32601, message: "Missing" } }, 3).error, "Missing");
});

test("only exposes allow-listed Homepage tools", () => {
  assert.equal(Mcp.makeToolCall(1, "read_config_file", { file: "services.yaml" }).method, "tools/call");
  assert.equal(Mcp.makeToolCall(1, "execute_shell", {}), null);
  assert.deepEqual(Mcp.parseTools({ tools: [{ name: "add_service" }, { name: "write_config_file" }] }), {
    ok: true, names: ["add_service", "write_config_file"]
  });
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
  assert.deepEqual(Mcp.parseValidation(invalid), { ok: true, valid: false, error: "bad indentation", mark: { line: 3, column: 4 } });
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
      callback({ ok: false, error: "Homepage MCP configuration changed; stale operation rejected." });
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
  assert.deepEqual(calls, ["validate_config_file"], "no stale write request should be sent");
});
