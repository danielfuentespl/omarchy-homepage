"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const HomepageApi = require("../HomepageApi.js");
const Model = require("../Model.js");

test("isolates the Homepage services endpoint and preserves safe base paths", () => {
  assert.deepEqual(HomepageApi.servicesUrl("https://homepage.example.test/home/", Model.normalizeBaseUrl, Model.originUrl), {
    ok: true, error: "", baseUrl: "https://homepage.example.test/home", url: "https://homepage.example.test/api/services"
  });
  assert.equal(HomepageApi.servicesUrl("https://user:pass@example.test", Model.normalizeBaseUrl, Model.originUrl).ok, false);
});

test("checks the Homepage JSON response media type before parsing", () => {
  const parse = payload => Model.parseServices(payload);
  assert.equal(HomepageApi.parseServicesResponse("application/problem+json", "[]", parse).ok, true);
  const rejected = HomepageApi.parseServicesResponse("text/html", "<html/>", parse);
  assert.equal(rejected.ok, false);
  assert.deepEqual(rejected.groups, []);
});
