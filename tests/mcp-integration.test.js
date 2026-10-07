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

test("in-memory Homepage fixture verifies the complete MCP write sequence and failure guards", async () => {
  const fixture = createHomepageServer({ token });
  const listed = await fixtureRpc(fixture, "tools/list", {}, 1);
  assert.equal(Mcp.parseTools(listed.result).names.includes("write_config_file"), true);

  const callTool = fixtureToolCaller(fixture);
  const invokeWorkflow = (workflow, ...args) => new Promise(resolve => workflow(callTool, ...args, resolve));
  const invalid = await invokeWorkflow(Mcp.writeAndVerifyServicesYaml, "INVALID_YAML\n");
  assert.equal(invalid.ok, false);
  assert.equal(fixture.state.writeCount, 0, "invalid YAML must not reach write_config_file");

  const yaml = "- Media:\n    - Jellyfin:\n        href: https://media.example.test\n";
  const saved = await invokeWorkflow(Mcp.writeAndVerifyServicesYaml, yaml);
  assert.equal(saved.ok, true, saved.error);
  assert.equal(fixture.state.yaml, yaml);
  assert.deepEqual(fixture.state.calls.map(call => call.name), [
    "", "validate_config_file", "validate_config_file", "write_config_file", "read_config_file"
  ]);

  const add = await invokeWorkflow(Mcp.addAndVerifyService, {
    group: "Media", name: "Jellyfin", service: { href: "https://media.example.test" }
  });
  assert.equal(add.ok, true, add.error);
  assert.deepEqual(fixture.state.calls.slice(-2).map(call => call.name), ["add_service", "read_config_file"]);

  const broken = createHomepageServer({ token, corruptReadback: true });
  const mismatch = await new Promise(resolve => Mcp.writeAndVerifyServicesYaml(fixtureToolCaller(broken), yaml, resolve));
  assert.equal(mismatch.ok, false);
  assert.equal(mismatch.writeMayHaveChanged, true);
  assert.equal(broken.state.writeCount, 1, "mismatched read-back must not trigger another write");
  assert.deepEqual(broken.state.calls.map(call => call.name), ["validate_config_file", "write_config_file", "read_config_file"]);
});

test("Homepage fixture exercises API, MCP tools, validation, write and read-back over verified TLS", async t => {
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

  const listed = callTool(endpoint.base, cert.caCertPath, "list_config_files", {}, 1);
  assert.equal(Mcp.parseWritableConfigFiles(listed.result).writable, true);
  const tools = listTools(endpoint.base, cert.caCertPath, 20);
  assert.equal(tools.ok, true);
  assert.ok(tools.names.includes("validate_config_file"));
  assert.ok(tools.names.includes("write_config_file"));
  const read = callTool(endpoint.base, cert.caCertPath, "read_config_file", { file: "services.yaml" }, 2);
  assert.match(Mcp.textFromToolResult(read.result).text, /Proxmox/);

  const invalidContent = "INVALID_YAML\n";
  let invalidResult;
  Mcp.writeAndVerifyServicesYaml(requestVia(endpoint.base, cert.caCertPath), invalidContent, value => { invalidResult = value; });
  assert.equal(invalidResult.ok, false);
  assert.match(invalidResult.error, /Invalid YAML fixture/);
  assert.equal(fixture.state.writeCount, 0, "write must not be sent after failed validation");

  const validContent = "- Media:\n    - Jellyfin:\n        href: https://media.example.test\n";
  let saved;
  Mcp.writeAndVerifyServicesYaml(requestVia(endpoint.base, cert.caCertPath), validContent, value => { saved = value; });
  assert.equal(saved.ok, true, saved.error);
  assert.equal(fixture.state.yaml, validContent);
  assert.deepEqual(fixture.state.calls.slice(-3).map(call => call.name), ["validate_config_file", "write_config_file", "read_config_file"]);

  let added;
  Mcp.addAndVerifyService(requestVia(endpoint.base, cert.caCertPath), {
    group: "Media", name: "Jellyfin", service: { href: "https://media.example.test" }
  }, value => { added = value; });
  assert.equal(added.ok, true, added.error);
  assert.deepEqual(fixture.state.calls.slice(-2).map(call => call.name), ["add_service", "read_config_file"]);

  assert.ok(fixture.state.authorizedRequests > 0);
  assert.equal(api.config.includes(token), false);
  assert.equal(JSON.stringify(api.argv).includes(token), false);
  assert.equal(JSON.stringify(api.env).includes(token), false);
  const authenticatedRequest = invoke(endpoint.base, cert.caCertPath, "POST",
    JSON.stringify(Mcp.makeToolCall(99, "tools/list", {})), 99);
  assert.equal(authenticatedRequest.config.includes(token), true, "the dummy token is sent only in curl stdin config");
  assert.equal(JSON.stringify(authenticatedRequest.argv).includes(token), false);
  assert.equal(JSON.stringify(authenticatedRequest.env).includes(token), false);
  assert.equal(authenticatedRequest.stdout.includes(token), false);
  assert.equal(authenticatedRequest.stderr.includes(token), false);
});

test("a mismatched read-back is reported without retrying or issuing another write", async t => {
  const cert = certificate(t);
  const fixture = createHomepageServer({ token, corruptReadback: true });
  const endpoint = await listen(t, fixture.server, cert);
  if (!endpoint) return;
  let outcome;
  Mcp.writeAndVerifyServicesYaml(requestVia(endpoint.base, cert.caCertPath), "- Test:\n    - One:\n", result => { outcome = result; });
  assert.equal(outcome.ok, false);
  assert.equal(outcome.writeMayHaveChanged, true);
  assert.equal(outcome.error, "Read-back did not match the saved content.");
  assert.equal(fixture.state.writeCount, 1);
  assert.deepEqual(fixture.state.calls.map(call => call.name), ["validate_config_file", "write_config_file", "read_config_file"]);
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
