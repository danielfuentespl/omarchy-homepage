"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const Curl = require("../CurlConfig.js");
const Model = require("../Model.js");
let loopbackAvailable;

function curl(url, options = {}, extraEnv = {}) {
  const marker = "OMAHP_TEST";
  const built = Curl.buildRequest({ method: options.method || "GET", url, timeoutSec: 3,
    maxBytes: options.maxBytes, caCertPath: options.caCertPath, token: options.token, body: options.body }, marker);
  assert.equal(built.ok, true, built.error);
  return spawnSync("curl", Curl.curlArguments(), {
    input: built.text,
    encoding: "utf8",
    env: { PATH: "/usr/bin:/bin", LANG: "C.UTF-8", LC_ALL: "C", ...extraEnv }
  });
}

test("builds a valid one-line curl write-out format", () => {
  const built = Curl.buildRequest({ method: "GET", url: "https://homepage.example.test/api/services", timeoutSec: 8 }, "OMAHP_FORMAT");
  assert.equal(built.ok, true, built.error);
  assert.match(built.text, /write-out = "%\{stderr\}OMAHP_FORMAT=%\{http_code\}\|%\{content_type\}\|%\{size_download\}\|%\{redirect_url\}"/);
  assert.deepEqual(Curl.parseOutput("[]", "OMAHP_FORMAT=200|application/json; charset=utf-8|2|", "OMAHP_FORMAT"), {
    ok: true, status: 200, contentType: "application/json", bytes: 2, redirectUrl: "", body: "[]", error: ""
  });
});

async function startServer(t, server, protocol = "http") {
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
  } catch (error) {
    if (error && error.code === "EPERM") {
      loopbackAvailable = false;
      t.skip("this sandbox blocks temporary loopback listeners; CI runs transport integration checks");
      return "";
    }
    throw error;
  }
  t.after(() => server.close());
  const url = `${protocol}://127.0.0.1:${server.address().port}`;
  const probe = spawnSync("curl", ["-q", "--max-time", "1", "--output", "/dev/null", `${url}/__omahp_probe`], {
    encoding: "utf8", env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" }
  });
  if (loopbackAvailable === undefined) loopbackAvailable = probe.status === 0;
  if (!loopbackAvailable) {
    t.skip("this sandbox blocks connections to temporary loopback servers; CI runs integration checks");
    return "";
  }
  return url;
}

test("curl reads configuration from stdin and returns body plus HTTP metadata", async t => {
  let hits = 0;
  const server = http.createServer((request, response) => {
    if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
    hits++;
    response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    response.end("[]");
  });
  const base = await startServer(t, server);
  if (!base) return;
  const response = curl(base + "/api/services");
  assert.equal(response.status, 0, response.stderr);
  assert.equal(response.stdout, "[]");
  const metadata = Curl.parseOutput(response.stdout, response.stderr, "OMAHP_TEST");
  assert.equal(metadata.ok, true, response.stderr);
  assert.equal(metadata.status, 200);
  assert.equal(metadata.contentType, "application/json");
  assert.equal(hits, 1);
});

test("rejects all redirect statuses without contacting destinations", async t => {
  for (const code of [301, 302, 303, 307, 308]) {
    let destinationHits = 0;
    const server = http.createServer((request, response) => {
      if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
      if (request.url === "/api/services") {
        response.writeHead(code, { location: "/target" });
        response.end("redirect");
      } else {
        destinationHits++;
        response.end("[]");
      }
    });
    const base = await startServer(t, server);
    if (!base) return;
    const response = curl(base + "/api/services");
    assert.equal(response.status, 0, response.stderr);
    assert.equal(Curl.parseOutput(response.stdout, response.stderr, "OMAHP_TEST").status, code);
    assert.equal(destinationHits, 0, `HTTP ${code} must not be followed`);
  }
});

test("-q is the first curl option and hostile curlrc cannot enable redirect following", async t => {
  assert.deepEqual(Curl.curlArguments(), ["-q", "--config", "-"]);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "omahome-curlrc-"));
  fs.writeFileSync(path.join(directory, ".curlrc"), "location\n");
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  let targetHits = 0;
  const server = http.createServer((request, response) => {
    if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
    if (request.url === "/api/services") { response.writeHead(301, { location: "/target" }); response.end(); }
    else { targetHits++; response.end("[]"); }
  });
  const base = await startServer(t, server);
  if (!base) return;
  const response = curl(base + "/api/services", {}, { HOME: directory });
  assert.equal(response.status, 0);
  assert.equal(targetHits, 0);
});

test("HTTPS rejects untrusted certificates and accepts an explicitly selected CA", async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "omahome-tls-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const keyPath = path.join(directory, "key.pem");
  const certPath = path.join(directory, "ca.pem");
  const generated = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", keyPath,
    "-out", certPath, "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"], { stdio: "ignore" });
  assert.equal(generated.status, 0, "openssl must create the temporary self-signed test CA");
  const server = https.createServer({ key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) }, (request, response) => {
    if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
    response.writeHead(200, { "content-type": "application/json" });
    response.end("[]");
  });
  const base = await startServer(t, server, "https");
  if (!base) return;
  const rejected = curl(base + "/api/services");
  assert.notEqual(rejected.status, 0);
  assert.equal(Curl.errorKind(rejected.status), "tls");
  const trusted = curl(base + "/api/services", { caCertPath: certPath });
  assert.equal(trusted.status, 0, trusted.stderr);
  assert.equal(Curl.parseOutput(trusted.stdout, trusted.stderr, "OMAHP_TEST").status, 200);
  assert.equal(trusted.stdout, "[]");
});

test("enforces transfer and parser size limits", async t => {
  const body = "x".repeat(Model.LIMITS.responseBytes + 100);
  const server = http.createServer((request, response) => {
    if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
    response.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
    response.end(body);
  });
  const base = await startServer(t, server);
  if (!base) return;
  const response = curl(base + "/api/services", { maxBytes: Model.LIMITS.responseBytes });
  assert.notEqual(response.status, 0);
  assert.ok(Buffer.byteLength(response.stdout) <= Model.LIMITS.responseBytes);
});

test("enforces the transfer limit for chunked responses without Content-Length", async t => {
  const body = "x".repeat(Model.LIMITS.responseBytes + 256 * 1024);
  const server = http.createServer((request, response) => {
    if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
    response.writeHead(200, { "content-type": "application/json", "transfer-encoding": "chunked" });
    response.end(body);
  });
  const base = await startServer(t, server);
  if (!base) return;
  const response = curl(base + "/api/services", { maxBytes: Model.LIMITS.responseBytes });
  assert.notEqual(response.status, 0);
  assert.ok(Buffer.byteLength(response.stdout) <= Model.LIMITS.responseBytes);
});

test("keeps MCP token only in stdin config, never in curl argv or environment", async t => {
  const token = "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6";
  let authorization = "";
  const server = http.createServer((request, response) => {
    if (request.url === "/__omahp_probe") { response.writeHead(204); response.end(); return; }
    authorization = request.headers.authorization || "";
    request.resume();
    request.on("end", () => { response.writeHead(200, { "content-type": "application/json" }); response.end('{"jsonrpc":"2.0","id":1,"result":{}}'); });
  });
  const base = await startServer(t, server);
  if (!base) return;
  const config = Curl.buildRequest({ method: "POST", url: base + "/api/mcp", timeoutSec: 3, token,
    body: '{"jsonrpc":"2.0","id":1,"method":"initialize"}' }, "OMAHP_TEST");
  assert.equal(config.ok, true);
  assert.equal(config.text.includes(token), true);
  const args = Curl.curlArguments();
  assert.equal(args.includes(token), false);
  const child = spawnSync("curl", args, { input: config.text, encoding: "utf8",
    env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" } });
  assert.equal(child.status, 0, child.stderr);
  assert.equal(authorization, "Bearer " + token);
  assert.equal(JSON.stringify(child.spawnargs).includes(token), false);
});

test("refuses to build an authenticated MCP request over HTTP", () => {
  const result = Curl.buildRequest({ method: "POST", url: "http://homepage.example.test/api/mcp", timeoutSec: 3,
    token: "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6", body: "{}" }, "OMAHP_HTTP_TOKEN");
  assert.equal(result.ok, false);
  assert.match(result.error, /HTTPS/);
});
