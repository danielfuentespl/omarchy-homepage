#!/usr/bin/env python3
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
assert manifest["schemaVersion"] == 1
assert manifest["id"] == "com.blogvirtualizado.omaops.homepage"
assert manifest["name"] == "OmaHomepage"
assert manifest["version"] == "0.1.0"
assert manifest["license"] == "MIT"
assert "independent project" in manifest["barWidget"]["disclaimer"].lower()
assert manifest["entryPoints"]["barWidget"] == "BarWidget.qml"
assert manifest["entryPoints"]["service"] == "Service.qml"
assert set(manifest["kinds"]) == {"service", "bar-widget"}
for entry in ("BarWidget.qml", "Panel.qml", "Service.qml", "HomepageApi.js", "CurlTransport.qml", "CurlConfig.js",
              "McpClient.qml", "McpClient.js", "Model.js", "ServiceHost.js", "README.md",
              "LICENSE", "CHANGELOG.md", "docs/SECURITY.md", "docs/preview.svg", "docs/preview.png",
              "DEVELOPMENT.md", "scripts/store-secret"):
    assert (root / entry).is_file(), f"missing {entry}"
workflow = (root / ".github/workflows/validate.yml").read_text(encoding="utf-8")
assert re.search(r"(?m)^permissions:\n  contents: read$", workflow), "CI repository permissions must remain read-only"
assert re.search(r"(?m)^    timeout-minutes: [1-9][0-9]*$", workflow), "CI job must have a timeout"
actions = re.findall(r"(?m)^\s+uses: ([^\s]+)", workflow)
assert actions and all(re.search(r"@[0-9a-f]{40}(?:\s+#|$)", action) for action in actions), "all CI actions must be pinned to full commit SHAs"
assert re.search(r"(?m)^\s+persist-credentials: false$", workflow), "checkout credentials must not persist"
assert re.search(r"(?m)^        run: \.\/tests\/run$", workflow), "CI should run the synthetic test suite"
assert not re.search(r"(?im)^\s+(?:uses|run): .*?(?:release|upload-artifact|publish)", workflow), "CI must not publish or create releases"
keys = {item["key"] for item in manifest["barWidget"]["schema"]}
assert keys == {"baseUrl", "refreshIntervalSec", "requestTimeoutMs", "staleAfterSec", "caCertPath", "secretId", "editingEnabled", "mcpPath"}
settings = {item["key"]: item for item in manifest["barWidget"]["schema"]}
assert settings["baseUrl"]["defaultValue"] == ""
assert settings["editingEnabled"]["defaultValue"] is False
assert manifest["barWidget"]["defaults"]["editingEnabled"] is False
assert "Homepage's MCP token" in manifest["barWidget"]["disclaimer"]
print("manifest, schema and repository files: OK")
