import QtQuick
import Quickshell.Io
import "Model.js" as Model
import "HomepageApi.js" as HomepageApi

Item {
  id: root

  property var settings: ({})
  property string apiState: "NOT CONFIGURED"
  property string apiMessage: "Set a Homepage address in plugin settings."
  property var serviceGroups: []
  property var services: []
  property bool refreshing: false
  property double lastSuccessMs: 0
  property date lastUpdated: new Date(0)
  property string mcpStatus: mcpClient.status
  property string mcpMessage: mcpClient.message
  property bool mcpWriteEnabled: mcpClient.writeEnabled
  property bool mcpAuthenticated: mcpClient.authenticated
  property bool mcpBusy: mcpClient.busy
  property bool editingEnabled: boolSetting("editingEnabled", false)
  property var baseUrlResult: Model.normalizeBaseUrl(setting("baseUrl", ""))
  property string baseUrl: baseUrlResult.ok ? baseUrlResult.value : ""
  property string mcpPath: String(setting("mcpPath", "/api/mcp") || "/api/mcp")
  property string secretId: String(setting("secretId", "default") || "default").trim() || "default"
  property string caCertPath: String(setting("caCertPath", "") || "").trim()
  property int refreshIntervalSec: Model.clampSeconds(setting("refreshIntervalSec", 60), 60, 30, 3600)
  property int requestTimeoutMs: Model.clampSeconds(setting("requestTimeoutMs", 8000), 8000, 1000, 30000)
  property int staleAfterSec: Model.clampSeconds(setting("staleAfterSec", 300), 300, 60, 86400)
  property int _generation: 0
  property int _requestId: 0
  property string _configKey: ""
  property var _apiCycle: null

  function setting(name, fallback) {
    const value = settings ? settings[name] : undefined;
    return value === undefined || value === null ? fallback : value;
  }

  function boolSetting(name, fallback) {
    const value = setting(name, fallback);
    return value === true || value === "true";
  }

  function configurationKey() {
    return JSON.stringify([
      String(setting("baseUrl", "")), String(setting("refreshIntervalSec", 60)),
      String(setting("requestTimeoutMs", 8000)), String(setting("staleAfterSec", 300)),
      String(setting("caCertPath", "") || ""), String(setting("secretId", "default") || "default"),
      String(setting("mcpPath", "/api/mcp") || "/api/mcp"), String(boolSetting("editingEnabled", false))
    ]);
  }

  function cancelOperations() {
    _generation++;
    const active = apiTransport.activeProcess;
    if (active) apiTransport.cancel(active.requestId);
    _apiCycle = null;
    refreshing = false;
    mcpClient.reset();
  }

  function current(cycle) {
    return cycle && cycle.generation === _generation && cycle.key === configurationKey();
  }

  function configurationChanged() {
    const key = configurationKey();
    if (key === _configKey) return;
    _configKey = key;
    cancelOperations();
    apiState = baseUrl ? "CONNECTING" : "NOT CONFIGURED";
    apiMessage = baseUrl ? "Connecting to Homepage." : "Set a Homepage address in plugin settings.";
    serviceGroups = [];
    services = [];
    lastSuccessMs = 0;
    lastUpdated = new Date(0);
    Qt.callLater(function() {
      root.refresh();
      root.checkMcp();
    });
  }

  function refreshIfStale() {
    if (!lastSuccessMs || Date.now() - lastSuccessMs >= refreshIntervalSec * 1000) refresh();
    checkMcpIfStale();
  }

  function checkMcpIfStale() {
    if (!mcpClient._checking && (!mcpClient.authenticated || !mcpClient.status.startsWith("MCP "))) checkMcp();
  }

  function checkMcp() {
    mcpClient.check({
      baseUrl: String(setting("baseUrl", "")),
      secretId,
      caCertPath,
      mcpPath,
      editingEnabled,
      requestTimeoutMs
    });
  }

  function refresh() {
    if (refreshing) return;
    const endpoint = HomepageApi.servicesUrl(String(setting("baseUrl", "")), Model.normalizeBaseUrl, Model.originUrl);
    if (!endpoint.ok) {
      apiState = "NOT CONFIGURED";
      apiMessage = endpoint.error;
      return;
    }
    const timeout = Math.max(1, Math.ceil(requestTimeoutMs / 1000));
    const cycle = {
      generation: _generation,
      key: configurationKey(),
      baseUrl: endpoint.baseUrl,
      caCertPath,
      timeoutSec: timeout
    };
    _apiCycle = cycle;
    refreshing = true;
    apiState = "CONNECTING";
    apiMessage = "Fetching Homepage services.";
    const id = ++_requestId;
    if (!apiTransport.start(id, {
      url: endpoint.url,
      method: "GET",
      timeoutSec: timeout,
      maxBytes: Model.LIMITS.responseBytes,
      caCertPath: cycle.caCertPath
    })) {
      refreshing = false;
      apiState = services.length ? Model.statusAfterFailure(true, (Date.now() - lastSuccessMs) / 1000, staleAfterSec) : "ERROR";
      apiMessage = "A Homepage request is already running.";
    }
  }

  function finishApiRequest(id, exitCode, statusCode, contentType, body, errorKind, errorMessage) {
    const cycle = _apiCycle;
    if (!current(cycle)) return;
    _apiCycle = null;
    refreshing = false;
    if (exitCode !== 0) {
      apiState = Model.apiState(0, exitCode, services.length > 0,
                               lastSuccessMs ? (Date.now() - lastSuccessMs) / 1000 : 0,
                               staleAfterSec);
      apiMessage = errorMessage || "Homepage request failed.";
      return;
    }
    if (statusCode === 401 || statusCode === 403 || (statusCode >= 300 && statusCode < 400)) {
      apiState = "AUTH REQUIRED";
      apiMessage = "Homepage requires a browser session for /api/services. The MCP token only authorizes /api/mcp.";
      return;
    }
    if (statusCode !== 200) {
      apiState = services.length ? Model.statusAfterFailure(true, (Date.now() - lastSuccessMs) / 1000, staleAfterSec) : "ERROR";
      apiMessage = statusCode === 404 ? "Homepage /api/services endpoint was not found." : "Homepage returned HTTP " + statusCode + ".";
      return;
    }
    const parsed = HomepageApi.parseServicesResponse(contentType, body, Model.parseServices);
    if (!parsed.ok) {
      apiState = "ERROR";
      apiMessage = parsed.error;
      return;
    }
    serviceGroups = parsed.groups;
    services = parsed.services;
    lastSuccessMs = Date.now();
    lastUpdated = new Date(lastSuccessMs);
    apiState = "ONLINE";
    apiMessage = "Homepage service configuration loaded.";
  }

  function addService(group, name, service, callback) {
    mcpClient.addService(group, name, service, function(result) {
      if (result.ok || result.writeMayHaveChanged === true) refresh();
      callback(result);
    });
  }

  function readServicesYaml(callback) { mcpClient.readServicesYaml(callback); }
  function validateServicesYaml(content, callback) { mcpClient.validateServicesYaml(content, callback); }
  function writeServicesYaml(content, callback) {
    mcpClient.writeServicesYaml(content, function(result) {
      if (result.ok || result.writeMayHaveChanged === true) refresh();
      callback(result);
    });
  }

  onSettingsChanged: configurationChanged()
  Component.onCompleted: configurationChanged()
  Component.onDestruction: cancelOperations()

  CurlTransport {
    id: apiTransport
    onCompleted: function(requestId, exitCode, statusCode, contentType, body, errorKind, errorMessage) {
      root.finishApiRequest(requestId, exitCode, statusCode, contentType, body, errorKind, errorMessage);
    }
  }

  McpClient {
    id: mcpClient
    onStatusChanged: {
      root.mcpStatus = status;
      root.mcpMessage = message;
      root.mcpWriteEnabled = writeEnabled;
      root.mcpAuthenticated = authenticated;
    }
    onMessageChanged: root.mcpMessage = message
    onWriteEnabledChanged: root.mcpWriteEnabled = writeEnabled
    onAuthenticatedChanged: root.mcpAuthenticated = authenticated
    onBusyChanged: root.mcpBusy = busy
  }
}
