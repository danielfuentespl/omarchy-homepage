"use strict";

// Documentation-only renderer. It consumes fictional fixtures and the plugin's
// production service model; it is never imported by the plugin at runtime.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const Model = require("../Model.js");

const root = path.resolve(__dirname, "..");
const output = path.join(root, "docs", "screenshots");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "omahomepage-docs-"));
const fixture = JSON.parse(fs.readFileSync(path.join(root, "docs/fixtures/homepage-demo.json"), "utf8"));
const parsed = Model.parseServices(JSON.stringify(fixture.groups));
if (!parsed.ok || Model.countGroups(parsed.groups) !== 3 || Model.countServices(parsed.groups) !== 7)
  throw new Error("Documentation fixture must parse to exactly three groups and seven services.");

const cert = fixture.certificate;
const esc = value => String(value).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
const style = `
  * { box-sizing: border-box; }
  html, body { margin: 0; min-height: 100%; background: #11101a; color: #08d0c9; }
  body { font: 14px/1.35 "DejaVu Sans Mono", "Liberation Mono", monospace; padding: 12px; }
  .demo-label { color: #bdb8c7; font-size: 11px; letter-spacing: .06em; margin: 0 0 8px 2px; }
  .panel { position: relative; width: 680px; border: 2px solid #e74778; background: #0d0818; padding: 16px 18px; }
  .header, .address, .row, .group-head, .service, .footer, .actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
  .header { font-size: 16px; padding: 2px 0 12px; border-bottom: 1px solid #5b2441; }
  .state { color: #d9ed58; font-size: 12px; font-weight: bold; }
  .state:before { content: ""; display: inline-block; width: 7px; height: 7px; margin-right: 8px; border-radius: 50%; background: currentColor; }
  .error { color: #ed3568; }
  .address { padding: 12px 0; color: #04d0c8; }
  .button { display: inline-block; border: 1px solid #05bdb8; padding: 7px 11px; color: #08d0c9; white-space: nowrap; }
  .button.secondary { border-color: #dc315f; color: #ec416e; }
  .button.focus { outline: 1px solid #d8ed57; color: #d8ed57; }
  .search, .input { height: 38px; border: 1px solid #193847; background: #101827; padding: 10px 12px; color: #08d0c9; }
  .search { margin: 0 0 12px; color: #497e86; }
  .search.active { color: #08d0c9; }
  .summary { color: #08d0c9; font-size: 12px; margin: 0 0 10px; }
  .notice { color: #d9ed58; font-size: 12px; padding: 4px 0 10px; }
  h2 { color: #08d0c9; font-size: 17px; margin: 12px 0 10px; }
  .tls-label { margin: 9px 0; font-weight: bold; }
  .actions { justify-content: flex-start; margin: 10px 0; }
  .detail { display: grid; grid-template-columns: 120px 1fr; gap: 4px 10px; font-size: 12px; margin: 8px 0; }
  .detail .key { color: #09d2cb; }
  .detail .value { color: #08d0c9; overflow-wrap: anywhere; }
  .fingerprint { font-size: 11px; letter-spacing: .01em; }
  .help { color: #08c9c2; font-size: 11px; line-height: 1.45; margin: 8px 0; }
  .ca-path { display: flex; gap: 10px; align-items: center; margin-top: 12px; }
  .ca-path .input { flex: 1; color: #42777d; overflow: hidden; white-space: nowrap; }
  .group-head { justify-content: flex-start; color: #08d0c9; padding: 8px 0 4px; }
  .group-head .arrow { width: 12px; text-align: center; }
  .service { padding: 8px 0 8px 26px; min-height: 42px; }
  .service-copy { flex: 1; }
  .service-name { font-weight: bold; color: #08d0c9; }
  .description { color: #08aaa7; font-size: 12px; }
  .footer { margin-top: 16px; }
  .overlay { position: absolute; inset: 0; background: rgba(4, 4, 10, .76); display: grid; place-items: center; padding: 12px; }
  .dialog { width: 540px; border: 1px solid #e74778; background: #0d0818; padding: 18px; box-shadow: 0 8px 32px #0009; }
  .dialog-message { white-space: pre-line; overflow-wrap: anywhere; line-height: 1.38; }
  .dialog .actions { justify-content: flex-end; margin: 20px 0 0; }
  .trust-title { color: #08d0c9; font-size: 15px; margin-bottom: 14px; }
`;

function page(content, name) {
  return `<!doctype html><html><head><meta charset="utf-8"><title>${esc(name)} · OmaHomepage demo</title><style>${style}</style></head><body><div class="demo-label">DOCUMENTATION PREVIEW · FICTIONAL FIXTURE DATA</div>${content}</body></html>`;
}

function common({ state = "ERROR", details = false, dialog = false } = {}) {
  const inspect = details ? `
    <div class="notice">TLS certificate not trusted · Private CA certificate</div>
    <div class="detail">
      <div class="key">Hostname</div><div class="value">${esc(cert.host)}</div>
      <div class="key">Subject</div><div class="value">${esc(cert.subject)}</div>
      <div class="key">Issuer</div><div class="value">${esc(cert.issuer)}</div>
      <div class="key">SAN</div><div class="value">${esc(cert.sans.join(", "))}</div>
      <div class="key">Valid until</div><div class="value">${esc(cert.validUntil)}</div>
      <div class="key">Valid from</div><div class="value">${esc(cert.validFrom)}</div>
      <div class="key">SHA-256</div><div class="value fingerprint">${esc(cert.fingerprint)}</div>
    </div>
    <div class="ca-path"><div class="input">Absolute path to public CA PEM (for example rootCA.pem)</div><span class="button">Import CA certificate</span></div>
    <div class="help">Import CA trusts certificates issued by that CA. Trust this certificate is limited to this exact leaf; a renewal needs approval again.</div>
    <div class="help">Trust this certificate: trusts only this exact leaf; approval is needed again if it changes.</div>
    <span class="button">Trust this certificate</span>` : `
    <h2>Configure Homepage</h2>
    <div class="input">${esc(fixture.baseUrl)}</div>
    <div class="tls-label">TLS · UNTRUSTED</div>
    <div class="actions"><span class="button">Test connection</span><span class="button">Inspect certificate</span></div>`;
  let content = `<main class="panel">
    <div class="header"><span>OmaHomepage</span><span class="state ${state === "ONLINE" ? "" : "error"}">${state}</span></div>
    <div class="address"><span>${esc(fixture.baseUrl)}</span><span>Configure</span></div>
    <div class="search">Search services…</div>
    <div class="summary">0 groups · 0 services</div>
    ${!details ? `<div class="notice">TLS certificate not trusted or invalid. Inspect the certificate in Configure Homepage.</div>` : ""}
    ${details ? `<h2>Configure Homepage</h2><div class="input">${esc(fixture.baseUrl)}</div><div class="tls-label">TLS · UNTRUSTED</div><div class="actions"><span class="button">Test connection</span><span class="button">Inspect certificate</span></div>` : ""}
    ${inspect}
    <div class="footer"><span class="button">Refresh</span><span></span><span>Open Homepage</span></div>
  </main>`;
  if (dialog) content = content.replace("</main>", `
    <div class="overlay"><div class="dialog">
      <div class="trust-title">Trust this certificate only for:<br>${esc(fixture.baseUrl)}</div>
      <div class="dialog-message">Hostname: ${esc(cert.host)}
Subject: ${esc(cert.subject)}
Issuer: ${esc(cert.issuer)}
SAN: ${esc(cert.sans.join(", "))}
Valid: ${esc(cert.validFrom)} — ${esc(cert.validUntil)}
SHA-256: ${esc(cert.fingerprint)}</div>
      <div class="actions"><span class="button">Cancel</span><span class="button focus">Trust certificate</span></div>
    </div></div></main>`);
  return content;
}

function connected() {
  const query = "o";
  const matchedGroups = Model.filterGroups(parsed.groups, query);
  const rows = Model.displayRows(matchedGroups, true, {});
  const rendered = rows.map(row => row.type === "group"
    ? `<div class="group-head"><span class="arrow">${row.expanded ? "▾" : "▸"}</span><span>${esc(row.name)} · ${row.count}</span></div>`
    : `<div class="service"><div class="service-copy"><div class="service-name">${esc(row.service.name)}</div><div class="description">${esc(row.service.description)}</div></div><span class="button">Open</span></div>`).join("");
  return `<main class="panel">
    <div class="header"><span>OmaHomepage</span><span class="state">ONLINE</span></div>
    <div class="address"><span>${esc(fixture.baseUrl)}</span><span>Configure</span></div>
    <div class="search active">${esc(query)}</div>
    <div class="summary">${Model.countGroups(parsed.groups)} groups · ${Model.countServices(parsed.groups)} services · ${Model.countServices(matchedGroups)} matches</div>
    ${rendered}
    <div class="footer"><span class="button">Refresh</span><span></span><span class="button">Open Homepage</span></div>
  </main>`;
}

fs.mkdirSync(output, { recursive: true });
const screenshots = [
  ["tls-certificate-untrusted.png", page(common(), "Private CA detected"), 720, 500],
  ["tls-trust-options.png", page(common({ details: true }), "Inspect and explicitly trust the certificate"), 720, 850],
  ["tls-trust-confirmation.png", page(common({ details: true, dialog: true }), "Confirm the certificate fingerprint"), 720, 850],
  ["homepage-online-services.png", page(connected(), "Connected to Homepage"), 720, 850]
];
const chromium = process.env.CHROMIUM_BIN || "chromium";
for (const [filename, html, width, height] of screenshots) {
  const input = path.join(temporary, filename + ".html");
  const target = path.join(output, filename);
  fs.writeFileSync(input, html);
  const result = spawnSync(chromium, ["--headless", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
    `--window-size=${width},${height}`, `--screenshot=${target}`, `file://${input}`], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`Could not render ${filename}: ${result.stderr || result.error}`);
  console.log(`${target}`);
}
fs.rmSync(temporary, { recursive: true, force: true });
