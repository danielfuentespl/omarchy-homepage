# Development

## Local checks

```sh
./tests/run
omarchy plugin validate .
git diff --check
```

Automated checks use Node.js, Python 3, curl and OpenSSL. HTTP/TLS integration tests use temporary loopback servers. They do not contact a real Homepage installation. Run the Omarchy CLI validator on a system with the native plugin runtime.

## Design

- `Model.js` owns URL safety, bounds, state mapping and normalized display data; `HomepageApi.js` isolates the root-relative `/api/services` URL and JSON-response handling. `baseUrl` paths are retained only for opening Homepage, because Homepage's UI requests its APIs from the origin root.
- `CurlConfig.js` builds requests and parses curl metadata. `CurlTransport.qml` launches curl using `-q --config -`, sends configuration via stdin, clears the environment and never enables redirects.
- `Service.qml` owns the API polling lifecycle and cancels stale requests when settings change.
- `McpClient.js` validates JSON-RPC results. `McpClient.qml` checks the opt-in MCP connection, reads its token from Secret Service, and allows only `list_config_files`, `read_config_file`, `validate_config_file`, `write_config_file` and `add_service`.
- `Panel.qml` reads `services.yaml` only after an explicit **Edit services.yaml** click. A user confirms after validation and before writes; verified writes replace the in-memory rollback snapshot, and uncertain writes offer a separately confirmed restore.
- No local YAML cache, Docker client/socket, Node, Python, YAML parser, or external runtime library is needed by the plugin. Runtime requires curl 8.4+ so `--max-filesize` also aborts oversized streaming responses.
- Service reachability is intentionally `UNKNOWN`; Homepage's `/api/services` response does not reliably identify each row's source.

## Secret storage

Run `scripts/store-secret [secret-id]` in a terminal to prompt without echo and save a token through `secret-tool`. The token does not appear in command arguments or plugin settings. Runtime lookups use `secret-tool lookup application omaops-homepage instance <secret-id>`. Delete with `secret-tool clear application omaops-homepage instance <secret-id>`.

## CI

GitHub Actions runs the synthetic test suite with read-only repository permissions. It does not run `omarchy plugin validate`; perform that check locally with Omarchy installed. The checkout action is pinned to a full commit SHA and does not persist credentials.
