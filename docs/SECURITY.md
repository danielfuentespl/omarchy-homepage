# Security notes

OmaHomepage is an independent client running inside `omarchy-shell`; it does not provide a sandbox or isolation boundary.

## Network requests and display

Plain HTTP is allowed only for read-only Homepage browsing when no MCP token is configured. It can list, search, and open services (for example, `http://homepage.local:3000`). MCP credentials always require HTTPS with successful TLS verification; HTTP plus an MCP token is rejected. HTTPS may use system trust, an imported CA, or an explicitly confirmed certificate. TLS verification is never disabled.

- The read-only path requests only `<baseUrl>/api/services`; optional read-only MCP uses `<origin><mcpPath>`.
- curl 8.4 or newer is invoked with `-q` first and `--config -`; generated URL, token and request body travel via stdin. The process receives a minimal environment. `--max-filesize` aborts oversized transfers, including chunked responses.
- Redirects are not followed. TLS verification is always enabled. Custom CAs are imported only after they validate the presented chain and hostname, then are scoped to the exact configured origin. An untrusted leaf, whether self-signed or issued by a private CA, can be trusted only after its validity and hostname pass checks and the user confirms its SHA-256 fingerprint. OmaHomepage stores only that public leaf and validates it with the normal curl transport against `/api/services` before saving the plugin setting; if curl rejects it as a trust anchor, the file is removed and the user is directed to import the issuing CA. A changed leaf remains blocked until a separate confirmation and curl verification. There is no `--insecure` option.
- Certificate inspection uses a TLS handshake only; it sends no HTTP request, MCP token or other credentials. It displays certificate metadata but never the public key or PEM. Imported certificates are public-only files in an OmaHomepage-owned `0700` directory, with `0600` file permissions; no global trust store is changed.
- Responses have byte limits, JSON media types are checked, display fields are allowlisted and bounded, and widget credentials/unknown fields are ignored.
- Links must be HTTP(S) with no embedded credentials and are opened using Qt rather than a shell.
- No Docker socket, SSH, browser cookie, Homepage session, or direct service probe is used.
- Per-service status is always `UNKNOWN`. Docker metadata is only a hint and source provenance is not inferred.

## Authentication limitations

When `HOMEPAGE_AUTH_ENABLED=true`, Homepage's `/api/services` endpoint is gated by its browser session. The Homepage MCP bearer token applies to `/api/mcp` only; it cannot authenticate `/api/services`. OmaHomepage does not request or store a browser cookie. MCP features may therefore work while the service list reports **AUTH REQUIRED**.

## MCP token scope

Homepage service browsing through `/api/services` does not depend on MCP. Homepage MCP requires Homepage v2.0.0 or newer; the integration has been validated against v2.4.0. If `/api/mcp` returns 404, only MCP is reported unavailable; the normal service listing remains available. The token is read from Secret Service (`application=omaops-homepage`, `instance=<secretId>`) and kept transiently in memory. The helper script accepts the token through a no-echo terminal prompt and pipes it to `secret-tool`; plugin settings never contain the token.

Homepage documents that MCP tokens can read configured credentials. By default, OmaHomepage permits only `read_config_file` with the exact filename `services.yaml`. Add Service requires the server's `HOMEPAGE_MCP_ALLOW_WRITE=true`, the explicit **Enable service editing** checkbox in Configure, authenticated HTTPS, advertised `add_service` and `write_config_file` tools, and Homepage reporting `services.yaml` as writable. The checkbox is a transient in-memory session authorization, defaulting to false and never stored in plugin settings. While an unsaved draft is active, it survives closing or recreating the panel; it is cleared when the draft is discarded, the service is added, the Homepage/TLS identity changes, or Omarchy Shell restarts. Its only production service write is a confirmation-based `add_service` with group, name, HTTP(S) URL, and optional description/icon. Ambiguous outcomes trigger read-back and never an automatic write retry. `write_config_file` is reserved for exact snapshot restoration in the test workflow; there is no YAML editing UI. Other tools, including `add_info_widget`, are rejected. The token is never sent over HTTP; MCP requires HTTPS with system trust or the origin-scoped custom trust. Protect the token and Homepage instance accordingly.

Viewing `services.yaml` requires an explicit user action and a sensitivity warning. The response is held in panel memory only while the local viewer is open. Error paths discard server-provided text so file contents are not copied into messages or logs. No automatic clipboard use or local persistence is performed.
## Reporting

Please report security issues privately to the project maintainer before public disclosure.
