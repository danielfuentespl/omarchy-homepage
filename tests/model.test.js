"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const Model = require("../Model.js");

test("normalizes an HTTP(S) Homepage address without credentials or query", () => {
  assert.deepEqual(Model.normalizeBaseUrl("https://homepage.example.test///"), {
    ok: true, value: "https://homepage.example.test", error: ""
  });
  assert.equal(Model.normalizeBaseUrl("https://home.example.test/homepage/").value, "https://home.example.test/homepage");
  assert.equal(Model.originUrl("https://home.example.test/homepage/"), "https://home.example.test");
  assert.equal(Model.normalizeBaseUrl("http://192.0.2.20:3000").value, "http://192.0.2.20:3000");
  for (const value of ["", "file:///tmp", "ftp://host", "https://u:p@host", "https://host/?x=1", "https://host/#x", "https://host/../admin", "http://999.1.1.1"]) {
    assert.equal(Model.normalizeBaseUrl(value).ok, false, value);
  }
});

test("validates service links without trusting their schemes, authority or controls", () => {
  for (const value of ["javascript:alert(1)", "file:///etc/passwd", "data:text/plain,x", "https://user:pw@example.test", "http://host:99999/", "http://host/\\evil", "http://host/\nX", "http://host/%zz"]) {
    assert.equal(Model.safeHttpUrl(value), "", value);
  }
  assert.equal(Model.safeHttpUrl("https://grafana.example.test/d/abc?orgId=1#view"), "https://grafana.example.test/d/abc?orgId=1#view");
  assert.equal(Model.safeHttpUrl("http://[::1]:3000/"), "http://[::1]:3000/");
});

test("accepts the current Homepage nested normalized group response", () => {
  const payload = JSON.stringify([
    { name: "Infrastructure", type: "group", services: [
      { name: "Proxmox", href: "https://pve.example.test", description: "Virtualization", server: "pve", container: "", widgets: [{ password: "ignored" }] }
    ], groups: [
      { name: "Network", type: "group", services: [{ name: "Pi-hole", href: "http://pihole.example.test/admin/" }], groups: [] }
    ] },
    { name: "Media", type: "group", services: [{ name: "Jellyfin", description: "Movies" }], groups: [] }
  ]);
  const result = Model.parseServices(payload);
  assert.equal(result.ok, true);
  assert.equal(result.services.length, 3);
  assert.equal(result.groups[0].groups[0].path, "Infrastructure / Network");
  assert.equal(result.groups[0].groups[0].services[0].name, "Pi-hole");
  assert.equal(result.services[0].dockerLinked, true);
  assert.equal(result.services[0].status, "UNKNOWN");
  assert.equal(result.services[2].linkAvailable, false);
  assert.equal(JSON.stringify(result).includes("ignored"), false);
});

test("accepts legacy test fixtures and limits displayed strings and item counts", () => {
  const services = Array.from({ length: 600 }, (_, index) => ({ name: "Service " + index, href: "http://service.example.test/" }));
  const result = Model.parseServices(JSON.stringify([{ Lab: services }]));
  assert.equal(result.ok, true);
  assert.equal(result.services.length, Model.LIMITS.services);
  const bounds = Model.parseServices(JSON.stringify([{ Lab: [{ name: "N".repeat(300), description: "D".repeat(1000) }] }]));
  assert.equal(bounds.services[0].name.length, Model.LIMITS.name);
  assert.equal(bounds.services[0].description.length, Model.LIMITS.description);
});

test("searches nested groups, names and descriptions while preserving hierarchy", () => {
  const result = Model.parseServices(JSON.stringify([
    { name: "Infrastructure", services: [{ name: "Proxmox" }], groups: [
      { name: "Monitoring", services: [{ name: "Grafana", description: "metrics" }], groups: [] }
    ] }
  ]));
  assert.equal(Model.filterGroups(result.groups, "grafana")[0].groups[0].services[0].name, "Grafana");
  assert.equal(Model.filterGroups(result.groups, "Infrastructure")[0].services[0].name, "Proxmox");
});

test("rejects malformed JSON, wrong root shape, and oversized payloads", () => {
  assert.equal(Model.parseServices("{").ok, false);
  assert.equal(Model.parseServices("{}").ok, false);
  assert.equal(Model.parseServices("[]", Model.LIMITS.responseBytes + 1).ok, false);
  assert.equal(Model.parseServices("x".repeat(Model.LIMITS.responseBytes + 1)).ok, false);
});

test("validates MCP paths and classifies protected API responses", () => {
  assert.equal(Model.normalizeMcpPath("/api/mcp"), "/api/mcp");
  for (const path of ["api/mcp", "//host/path", "/api/../other", "/api/mcp?x=1", "/api/%2e%2e/other"]) assert.equal(Model.normalizeMcpPath(path), "", path);
  assert.equal(Model.apiState(307, 0, false, 0, 300), "AUTH REQUIRED");
  assert.equal(Model.apiState(200, 0, false, 0, 300), "ONLINE");
  assert.equal(Model.apiState(0, 7, true, 60, 300), "OFFLINE");
  assert.equal(Model.apiState(0, 7, true, 400, 300), "STALE");
});
