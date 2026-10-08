# Security notes

OmaHomepage is an independent client running inside `omarchy-shell`; it does not provide a sandbox or isolation boundary.

## Network requests and display

- The read-only path requests only `<baseUrl>/api/services`; optional management uses `<baseUrl>/api/mcp`.
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

MCP is not contacted until the user explicitly enables editing in plugin settings. The token is read from Secret Service (`application=omaops-homepage`, `instance=<secretId>`) and kept transiently in memory. The helper script accepts the token through a no-echo terminal prompt and pipes it to `secret-tool`; plugin settings never contain the token.

Homepage documents that MCP tokens can read configured credentials; with writes enabled they can modify broader configuration, including `custom.js`. OmaHomepage limits its own call sites to a small allowlist and offers service-specific flows, but cannot reduce the server-side permissions of that bearer token. The token is never sent over HTTP; MCP is blocked unless the configured base URL uses HTTPS and curl verifies it with system trust or the origin-scoped custom trust. The user must enable `HOMEPAGE_MCP_ALLOW_WRITE=true` on Homepage and independently opt in to editing in plugin settings. Protect the token and Homepage instance accordingly.

The YAML editor is opened only by explicit user action. Its contents remain in panel memory while open. Saving calls Homepage validation, requests explicit user confirmation, writes `services.yaml`, then reads it back and checks an exact match. Adding a service also requires explicit confirmation and reads back the resulting file. If a write response is interrupted or read-back fails, Homepage may already have changed: the service list is refreshed, no write is retried automatically, and the panel offers a separate, explicit restore of the last verified YAML snapshot when available. Restoring can overwrite concurrent edits. These checks do not make Homepage MCP writes transactional.

## Reporting

Please report security issues privately to the project maintainer before public disclosure.
