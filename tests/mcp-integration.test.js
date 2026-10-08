"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const https = require("node:https");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const Curl = require("../CurlConfig.js");
const Mcp = require("../McpClient.js");
const Model = require("../Model.js");
const HomepageApi = require("../HomepageApi.js");
const { createHomepageServer } = require("./fixtures/homepage-server.js");

const token = "fixture-only-token-value-that-is-not-real-123456";
let loopbackAvailable;

function certificate(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "omahome-mcp-fixture-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const key = path.join(directory, "key.pem");
  const cert = path.join(directory, "ca.pem");
  const generated = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
    "-out", cert, "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"], { stdio: "ignore" });
  assert.equal(generated.status, 0, "openssl must create the temporary fixture CA");
  return { key: fs.readFileSync(key), cert: fs.readFileSync(cert), caCertPath: cert };
}

async function listen(t, server, cert, options = {}) {
  const tlsServer = https.createServer({ key: cert.key, cert: cert.cert }, server.listeners("request")[0]);
  try {
    await new Promise((resolve, reject) => {
      tlsServer.once("error", reject);
      tlsServer.listen(0, "127.0.0.1", resolve);
    });
  } catch (error) {
    if (error && error.code === "EPERM") {
      if (process.env.CI) throw new Error("CI must permit temporary loopback listeners for Homepage MCP integration tests");
      t.skip("sandbox blocks temporary loopback servers"); return null;
    }
    throw error;
  }
  t.after(() => new Promise(resolve => tlsServer.close(resolve)));
  const base = `https://127.0.0.1:${tlsServer.address().port}`;
  const probe = spawnSync("curl", ["-q", "--cacert", cert.caCertPath, "--max-time", "1", "--output", "/dev/null", base + "/__omahp_probe"], {
    encoding: "utf8", env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" }
  });
  if (loopbackAvailable === undefined) loopbackAvailable = probe.status === 0;
  if (!loopbackAvailable) {
    if (process.env.CI) throw new Error("CI must permit connections to temporary Homepage fixture servers");
    t.skip("sandbox blocks connections to temporary loopback servers"); return null;
  }
  return { base, ...options };
}

function invoke(base, caCertPath, method, body, id = 1, requestToken = token, timeoutSec = 2) {
  const built = Curl.buildRequest({ method, url: base + (method === "GET" ? "/api/services" : "/api/mcp"),
    timeoutSec, maxBytes: 512 * 1024, caCertPath, token: method === "POST" ? requestToken : "", body: method === "POST" ? body : "" }, "OMAHP_FIXTURE");
  assert.equal(built.ok, true, built.error);
  const child = spawnSync("curl", Curl.curlArguments(), {
    input: built.text,
    encoding: "utf8",
    env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" }
  });
  const parsed = Curl.parseOutput(child.stdout, child.stderr, "OMAHP_FIXTURE");
  return { exitCode: child.status, stdout: child.stdout, stderr: child.stderr, parsed,
    argv: child.spawnargs || [], env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" }, config: built.text };
}

function callTool(base, caCertPath, name, args, id) {
  const request = Mcp.makeToolCall(id, name, args);
  const result = invoke(base, caCertPath, "POST", JSON.stringify(request), id);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.equal(result.parsed.status, 200);
  const response = Mcp.parseRpcResponse(result.stdout, id);
  return response.ok ? { ok: true, result: response.result } : response;
}

function listTools(base, caCertPath, id) {
  const result = invoke(base, caCertPath, "POST", JSON.stringify(Mcp.rpcRequest(id, "tools/list", {})), id);
  assert.equal(result.exitCode, 0, result.stderr);
  const response = Mcp.parseRpcResponse(result.stdout, id);
  assert.equal(response.ok, true, response.error);
  return Mcp.parseTools(response.result);
}

function requestVia(base, caCertPath) {
  let id = 0;
  return (name, args, callback) => callback(callTool(base, caCertPath, name, args, ++id));
}

async function fixtureRpc(fixture, method, params, id) {
  const request = {
    url: "/api/mcp", method: "POST", headers: { authorization: "Bearer " + token },
    async *[Symbol.asyncIterator]() { yield Buffer.from(JSON.stringify({ jsonrpc: "2.0", id, method, params })); }
  };
  const response = {
    status: 0, headersSent: false, body: "",
    writeHead(status) { this.status = status; this.headersSent = true; },
    end(body) { this.body = String(body || ""); }
  };
  await fixture.handleRequest(request, response);
  assert.equal(response.status, 200);
  return Mcp.parseRpcResponse(response.body, id);
}

function fixtureToolCaller(fixture) {
  let id = 0;
  return (name, args, callback) => {
    fixtureRpc(fixture, "tools/call", { name, arguments: args }, ++id).then(rpc => {
      callback(rpc.ok ? { ok: true, result: rpc.result } : rpc);
    });
  };
}

test("in-memory Homepage MCP read-only phase lists tools and reads services.yaml without any write call", async () => {
  const fixture = createHomepageServer({ token });
  const listed = await fixtureRpc(fixture, "tools/list", {}, 1);
  const tools = Mcp.parseTools(listed.result);
  assert.equal(tools.ok, true);
  assert.ok(tools.names.includes("read_config_file"));
  assert.ok(tools.names.includes("validate_config_file"));
  assert.ok(tools.names.includes("add_service"));
  assert.ok(tools.names.includes("write_config_file"));

  const toolRequest = Mcp.makeToolCall(2, "read_config_file", { file: "services.yaml" });
  assert.ok(toolRequest);
  const rpc = await fixtureRpc(fixture, toolRequest.method, toolRequest.params, 2);
  assert.match(Mcp.textFromToolResult(rpc.result).text, /Proxmox/);
  assert.equal(Mcp.makeToolCall(3, "read_config_file", { file: "settings.yaml" }), null);
  assert.equal(Mcp.makeToolCall(4, "write_config_file", { file: "services.yaml", content: "bad" }), null);
  assert.deepEqual(fixture.state.calls.map(call => [call.method, call.name]), [["tools/list", ""], ["tools/call", "read_config_file"]]);
  assert.equal(fixture.state.writeCount, 0);
});

test("Homepage fixture lists capabilities and reads only services.yaml over verified TLS", async t => {
  const cert = certificate(t);
  const fixture = createHomepageServer({ token });
  const endpoint = await listen(t, fixture.server, cert);
  if (!endpoint) return;

  const api = invoke(endpoint.base, cert.caCertPath, "GET", "");
  assert.equal(api.exitCode, 0, api.stderr);
  assert.equal(api.parsed.status, 200);
  const endpointInfo = HomepageApi.servicesUrl(endpoint.base, Model.normalizeBaseUrl, Model.originUrl);
  assert.equal(endpointInfo.url, endpoint.base + "/api/services");
  assert.equal(Model.parseServices(api.stdout).services[0].name, "Proxmox");

  const tools = listTools(endpoint.base, cert.caCertPath, 20);
  assert.equal(tools.ok, true);
  for (const name of ["read_config_file", "validate_config_file", "add_service", "write_config_file"])
    assert.ok(tools.names.includes(name));
  const read = callTool(endpoint.base, cert.caCertPath, "read_config_file", { file: "services.yaml" }, 2);
  assert.match(Mcp.textFromToolResult(read.result).text, /Proxmox/);

  const attemptedOtherFile = Mcp.makeToolCall(3, "read_config_file", { file: "widgets.yaml" });
  const attemptedWrite = Mcp.makeToolCall(4, "write_config_file", { file: "services.yaml", content: "" });
  assert.equal(attemptedOtherFile, null);
  assert.equal(attemptedWrite, null);
  assert.equal(fixture.state.writeCount, 0);
  assert.deepEqual(fixture.state.calls.map(call => [call.method, call.name]), [
    ["tools/list", ""], ["tools/call", "read_config_file"]
  ]);
  assert.ok(fixture.state.authorizedRequests > 0);
  assert.equal(api.config.includes(token), false);
  assert.equal(JSON.stringify(api.argv).includes(token), false);
  assert.equal(JSON.stringify(api.env).includes(token), false);
  const authenticatedRequest = invoke(endpoint.base, cert.caCertPath,
    "POST", JSON.stringify(Mcp.rpcRequest(99, "tools/list", {})), 99);
  assert.equal(authenticatedRequest.exitCode, 0);
  assert.equal(authenticatedRequest.config.includes(token), true, "the fixture token is sent only in curl stdin config");
  assert.equal(JSON.stringify(authenticatedRequest.argv).includes(token), false);
  assert.equal(JSON.stringify(authenticatedRequest.env).includes(token), false);
  assert.equal(authenticatedRequest.stdout.includes(token), false);
  assert.equal(authenticatedRequest.stderr.includes(token), false);
  for (const file of fs.readdirSync(path.dirname(cert.caCertPath))) {
    assert.equal(fs.readFileSync(path.join(path.dirname(cert.caCertPath), file), "utf8").includes(token), false);
  }
});


test("MCP disabled, auth failures, malformed JSON-RPC and missing result are reported without following redirects", async t => {
  for (const scenario of [
    { mcpStatus: 401, expected: 401 },
    { mcpStatus: 403, expected: 403 },
    { mcpStatus: 404, expected: 404 },
    { mcpStatus: 500, expected: 500 },
    { mcpBody: "not-json", malformed: true },
    { mcpWrongId: true, wrongId: true },
    { mcpMissingResult: true, missingResult: true }
  ]) {
    const cert = certificate(t);
    const fixture = createHomepageServer(scenario);
    const endpoint = await listen(t, fixture.server, cert);
    if (!endpoint) return;
    const result = invoke(endpoint.base, cert.caCertPath, "POST",
      JSON.stringify(Mcp.rpcRequest(5, "tools/list", {})), 5, token, 2);
    assert.equal(result.exitCode, 0, result.stderr);
    assert.equal(result.parsed.status, scenario.expected || 200);
    if (scenario.malformed) assert.equal(Mcp.parseRpcResponse(result.stdout, 5).ok, false);
    if (scenario.wrongId) assert.equal(Mcp.parseRpcResponse(result.stdout, 5).ok, false);
    if (scenario.missingResult) assert.match(Mcp.parseRpcResponse(result.stdout, 5).error, /no result/);
  }
});

test("MCP rejects every redirect status and never reaches a redirect destination", async t => {
  for (const code of [301, 302, 303, 307, 308]) {
    let destinationHits = 0;
    const fixture = createHomepageServer({ mcpRedirect: code });
    // Track redirect targets while retaining the fixture's MCP response behavior.
    const cert = certificate(t);
    const tlsServer = https.createServer({ key: cert.key, cert: cert.cert }, (request, response) => {
      if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
      if (request.url === "/mcp-target") destinationHits++;
      fixture.handleRequest(request, response);
    });
    const endpoint = await listen(t, tlsServer, cert);
    if (!endpoint) return;
    const result = invoke(endpoint.base, cert.caCertPath, "POST",
      JSON.stringify(Mcp.rpcRequest(1, "tools/list", {})), 1, token, 2);
    assert.equal(result.exitCode, 0, result.stderr);
    assert.equal(result.parsed.status, code);
    assert.equal(destinationHits, 0);
  }
});

test("MCP timeout is bounded and an invalid bearer token is rejected", async t => {
  const cert = certificate(t);
  const fixture = createHomepageServer({ token, mcpDelayMs: 1500 });
  const endpoint = await listen(t, fixture.server, cert);
  if (!endpoint) return;
  const timed = invoke(endpoint.base, cert.caCertPath, "POST",
    JSON.stringify(Mcp.rpcRequest(1, "tools/list", {})), 1, token, 1);
  assert.equal(timed.exitCode, 28);

  const authFixture = createHomepageServer({ token });
  const authEndpoint = await listen(t, authFixture.server, cert);
  if (!authEndpoint) return;
  const wrong = invoke(authEndpoint.base, cert.caCertPath, "POST",
    JSON.stringify(Mcp.rpcRequest(2, "tools/list", {})), 2, "wrong-token-value-that-is-definitely-not-valid-000", 2);
  assert.equal(wrong.exitCode, 0);
  assert.equal(wrong.parsed.status, 401);
});

test("Homepage fixture simulates auth failures, server errors, malformed JSON and timeouts", async t => {
  for (const scenario of [
    { servicesStatus: 401, expectedStatus: 401 },
    { servicesStatus: 403, expectedStatus: 403 },
    { servicesStatus: 404, expectedStatus: 404 },
    { servicesStatus: 500, expectedStatus: 500 },
    { servicesBody: "not-json", expectedStatus: 200, malformed: true },
    { servicesRedirect: true, expectedStatus: 302 },
    { delayServicesMs: 1300, timeout: true }
  ]) {
    const cert = certificate(t);
    const fixture = createHomepageServer(scenario);
    const endpoint = await listen(t, fixture.server, cert);
    if (!endpoint) return;
    const result = invoke(endpoint.base, cert.caCertPath, "GET", "", 1, token, 1);
    if (scenario.timeout) assert.equal(result.exitCode, 28, "delayed fixture should exceed curl's one second timeout");
    else {
      assert.equal(result.exitCode, 0, result.stderr);
      assert.equal(result.parsed.status, scenario.expectedStatus);
      if (scenario.malformed) assert.equal(Model.parseServices(result.stdout).ok, false);
    }
  }
});
