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
              "DEVELOPMENT.md", "scripts/store-secret", "scripts/certificate_helper.py",
              "tests/certificate_helper.test.py", "session/qmldir", "session/SessionState.qml",
              "tests/qml/tst_session_lifecycle.qml"):
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
assert keys == {"baseUrl", "refreshIntervalSec", "requestTimeoutMs", "staleAfterSec", "caCertPath", "tlsTrustMode",
                "tlsTrustOrigin", "tlsTrustFingerprint", "secretId", "mcpPath"}
settings = {item["key"]: item for item in manifest["barWidget"]["schema"]}
assert settings["baseUrl"]["defaultValue"] == ""
assert settings["tlsTrustMode"]["defaultValue"] == "system"
assert "Homepage's MCP token" in manifest["barWidget"]["disclaimer"]
assert "editingEnabled" not in manifest["barWidget"]["defaults"]
assert "editingEnabled" not in settings
panel = (root / "Panel.qml").read_text(encoding="utf-8")
assert "View services.yaml" in panel and "root.requestYamlView()" in panel
assert "services.yaml may contain API keys, tokens or passwords" in panel
assert "HOMEPAGE_MCP_ALLOW_WRITE" in manifest["barWidget"]["disclaimer"]
assert "service.mcpServerWriteAvailable === true" in panel
assert 'text: root.configEditing ? "Done" : "Configure"' in panel
assert 'onClicked: root.toggleConfiguration()' in panel
assert 'visible: root.configEditing' in panel
assert 'resultsFlickable.contentY = Math.max(0, configSection.y)' in panel
assert "function toggleConfiguration()" in panel
assert "if (configEditing)" in panel and "else {\n      beginConfigEditing()" in panel
assert 'text: "Enable service editing"' in panel
assert 'onToggled: root.service.setEditingEnabled(checked)' in panel
assert "resetEditingSession()" in panel and "onOpenedChanged" in panel
assert "service.setEditingEnabled(false)" in panel
assert "MCP · " in panel and "root.service.mcpStatus" in panel
assert "service.editingEnabled === true && service.mcpAuthenticated === true" in panel
assert "service.mcpServerWriteAvailable === true && service.mcpWriteEnabled === true" in panel
assert 'text: root.addServiceVisible ? "Close form" : "+ Add service"' in panel and "visible: root.writeControlsReady" in panel
assert "visible: root.addServiceVisible" in panel
assert 'onClicked: root.addServiceVisible ? root.closeAddServiceForm() : root.openAddServiceForm()' in panel
open_form = panel.split("function openAddServiceForm()", 1)[1].split("function closeAddServiceForm()", 1)[0]
assert "if (!writeControlsReady || service.mcpBusy) return" in open_form
assert "service.beginAddServiceDraft()" in open_form
assert "resultsFlickable.contentY" in open_form and "addFormSection.y" in open_form
assert "service.addService" not in open_form, "opening the form must never send an MCP write"
assert 'text: "Continue"' in panel and 'onClicked: root.addService()' in panel
assert "function closeAddServiceForm()" in panel and "service.clearAddServiceDraft()" in panel
assert 'onClicked: root.closeAddServiceForm()' in panel
assert "function cancelAddConfirmation() {\n    closeAddServiceForm()" in panel
cancel_form = panel.split("function closeAddServiceForm()", 1)[1].split("function switchPanel", 1)[0]
assert "service.addService" not in cancel_form, "cancel must never send an MCP write"
assert "onReturnRequested" in panel and "root.confirmAddService()" not in panel.split("onReturnRequested", 1)[1].split("onTabRequested", 1)[0], \
    "Enter must not confirm an Add service write"
assert 'opened: root.addConfirmOpen && root.addServiceVisible' in panel and 'confirmText: "Add service"' in panel
assert "if (!addConfirmOpen || !writeControlsReady || service.mcpBusy) return" in panel
assert panel.count("service.addService(group, name") == 1, "the write is only called from explicit confirmation"
assert "Close form" in panel
assert 'readonly property var addDraft: service.addServiceDraft ||' in panel
assert 'readonly property bool addServiceVisible: addDraft.formOpen === true' in panel
for field, qml_id in (("group", "addGroupInput"), ("name", "newNameInput"), ("href", "newHrefInput"),
                      ("description", "newDescriptionInput"), ("icon", "newIconInput")):
    assert f'text: root.addDraft.{field}' in panel, f"{field} must be restored from the service-session draft"
    assert f'updateAddServiceDraft("{field}", text)' in panel, f"{field} must be stored in the service-session draft"
assert "if (addServiceVisible) return" in panel, "opening/closing the popup must retain edit authorization while a draft is active"
assert 'notice = "Unsaved service draft restored."' in panel
assert 'visible: root.notice === "Unsaved service draft restored."' in panel
assert "scrollToAddServiceForm(false)" in panel
opened_changed = panel.split("onOpenedChanged: {", 1)[1].split("onConfigDraftChanged:", 1)[0]
assert "scrollToAddServiceForm(false)" in opened_changed
assert "closeAddServiceForm()" not in opened_changed, "temporary popup hide must not discard the draft"
assert "service.addService(" not in opened_changed, "hide/reopen must not perform MCP writes"
assert "root.confirmAddService()" not in panel.split("onReturnRequested", 1)[1].split("onTabRequested", 1)[0]
assert "opened: root.addConfirmOpen && root.addServiceVisible" in panel
service = (root / "Service.qml").read_text(encoding="utf-8")
assert 'import "session" as OmaSession' in service
assert "readonly property bool editingEnabled: OmaSession.SessionState.editingEnabled" in service
assert 'setting("editingEnabled"' not in service
assert "function setEditingEnabled(value)" in service
assert 'OmaSession.SessionState.draftActive' in service and 'OmaSession.SessionState.formOpen' in service
assert "function beginAddServiceDraft()" in service and "function updateAddServiceDraft(field, value)" in service
assert "function clearAddServiceDraft()" in service
context = service.split("function draftContextKey()", 1)[1].split("function updateAddServiceDraft", 1)[0]
for context_item in ("baseUrl", "secretId", "caCertPath", "tlsTrustMode", "tlsTrustOrigin", "tlsTrustFingerprint", "mcpPath"):
    assert context_item in context, f"draft context must include {context_item}"
assert "OmaSession.SessionState.setIdentity(draftContextKey())" in service
destruction = service.split("Component.onDestruction", 1)[1]
assert "cancelOperations()" in destruction and "clearAddServiceDraft" not in destruction
assert "discardDraft()" in service and "SessionState" in service
assert "if (result.ok) {\n        closeAddServiceForm()" in panel, "successful Add service must clear its draft"
assert "addServiceDraft" not in manifest["barWidget"]["defaults"]
assert "addServiceDraft" not in settings
session_state = (root / "session/SessionState.qml").read_text(encoding="utf-8")
assert "pragma Singleton" in session_state
assert "function beginDraft()" in session_state and "function discardDraft()" in session_state
assert all(f"property string {field}: \"\"" in session_state for field in ("group", "name", "href", "description", "icon"))
assert not re.search(r"(?i)(settings|secret.?service|sqlite|localstorage|console\.log|fileio)", session_state)
assert "Add temporary service?" in panel
assert "Advanced fields" not in panel and "newServerInput" not in panel
assert "Validate & Save" not in panel and "root.yamlConfirmOpen" not in panel
client = (root / "McpClient.qml").read_text(encoding="utf-8")
assert "writeEnabled = false" in client
assert 'if (httpStatus === 404) status = "MCP UNAVAILABLE"' in client
assert "Homepage MCP requires Homepage v2.0.0 or newer" in (root / "README.md").read_text(encoding="utf-8")
assert "validated against v2.4.0" in (root / "docs/SECURITY.md").read_text(encoding="utf-8")

assert "QtQuick.Dialogs" not in panel and "FileDialog" not in panel, "avoid the crashing GTK/GVFS file picker"
assert "Absolute path to public CA PEM" in panel and "root.importSelectedCa()" in panel
assert 'runTlsHelper("trust-leaf"' in panel and "leafVerifyTransport.start" in panel
assert "rollbackLeafTrust" in panel and "This TLS backend cannot use the presented certificate as a trust anchor" in panel
print("manifest, schema and repository files: OK")
