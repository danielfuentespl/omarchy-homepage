import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "McpClient.js" as Mcp

Item {
  id: root

  property string status: "MCP UNAVAILABLE"
  property string message: ""
  property bool writeEnabled: false
  property bool serverWriteAvailable: false
  property bool readEnabled: false
  property bool authenticated: false
  property bool operationBusy: false
  readonly property bool busy: operationBusy || _checking
  property var tools: []
  property string _token: ""
  property string _configKey: ""
  property int _generation: 0
  property int _requestId: 0
  property var _cycle: null
  property var _requestCallback: null
  property var _requestCancelCallback: null
  property var _lookup: null
  property bool _checking: false

  function configurationKey(spec) {
    return Mcp.configurationKey(spec);
  }

  function cancel() {
    _generation++;
    var lookup = _lookup;
    _lookup = null;
    if (lookup) {
      lookup.cancelled = true;
      lookup.running = false;
      lookup.destroy();
    }
    var cancelRequest = _requestCancelCallback;
    _requestCancelCallback = null;
    _requestCallback = null;
    var active = transport.activeProcess;
    if (active) transport.cancel(active.requestId);
    _cycle = null;
    _token = "";
    _checking = false;
    operationBusy = false;
    if (cancelRequest) cancelRequest();
  }

  function reset() {
    cancel();
    _configKey = "";
    status = "MCP UNAVAILABLE";
    message = "";
    writeEnabled = false;
    serverWriteAvailable = false;
    readEnabled = false;
    authenticated = false;
    operationBusy = false;
    tools = [];
  }

  function current(cycle) {
    return cycle && cycle.generation === _generation && cycle.key === _configKey;
  }

  function check(spec) {
    cancel();
    writeEnabled = false;
    serverWriteAvailable = false;
    readEnabled = false;
    authenticated = false;
    tools = [];
    _configKey = configurationKey(spec);
    const generation = _generation;
    const url = Model.normalizeBaseUrl(spec.baseUrl);
    const mcpPath = Model.normalizeMcpPath(spec.mcpPath || "/api/mcp");
    if (!url.ok || !mcpPath) {
      status = "MCP UNAVAILABLE";
      message = "Configure a valid Homepage address and MCP path.";
      writeEnabled = false;
      return;
    }
    _cycle = {
      generation,
      key: _configKey,
      baseUrl: url.value,
      origin: Model.originUrl(url.value),
      serviceGeneration: spec.generation,
      tlsTrustMode: spec.tlsTrustMode || "system",
      tlsTrustOrigin: spec.tlsTrustOrigin || "",
      tlsTrustFingerprint: spec.tlsTrustFingerprint || "",
      editingEnabled: spec.editingEnabled === true,
      mcpPath,
      secretId: spec.secretId || "default",
      caCertPath: spec.caCertPath || "",
      timeoutSec: Math.max(1, Math.ceil(Number(spec.requestTimeoutMs || 8000) / 1000))
    };
    _checking = true;
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(_cycle.secretId)) {
      _checking = false;
      status = "MCP AUTHENTICATION FAILED";
      message = "Secret Service token ID must use 1–64 letters, digits, dots, underscores or hyphens.";
      return;
    }
    if (_cycle.origin.indexOf("https://") !== 0) {
      _checking = false;
      status = "MCP AUTH REQUIRES HTTPS";
      message = "Homepage MCP credentials are never sent over HTTP. Use an HTTPS address to enable MCP.";
      writeEnabled = false;
      authenticated = false;
      return;
    }
    status = "MCP CHECKING";
    message = "";
    writeEnabled = false;
    lookupSecret(_cycle);
  }

  function lookupSecret(cycle) {
    if (!current(cycle)) return;
    _lookup = lookupComponent.createObject(root, { cycle: cycle, running: true });
    if (!_lookup) {
      finishLookup(cycle, -2, "");
      return;
    }
  }

  function finishLookup(cycle, exitCode, output, errorOutput) {
    if (!current(cycle)) return;
    _lookup = null;
    _token = "";
    if (exitCode === 0) {
      const candidate = String(output || "").replace(/[\r\n]+$/, "");
      if (candidate.length >= 32 && /^[A-Za-z0-9_+/=-]+$/.test(candidate)) _token = candidate;
      else if (candidate) {
        status = "MCP AUTHENTICATION FAILED";
        message = "The stored Homepage MCP token is invalid; replace it in Secret Service.";
        _checking = false;
        return;
      }
      listTools(cycle, _token);
      return;
    }
    if (exitCode === 1) {
      if (String(errorOutput || "").trim() !== "") {
        status = "MCP AUTH REQUIRED";
        message = "Could not access Secret Service for the Homepage MCP token.";
        _checking = false;
        return;
      }
      listTools(cycle, "");
      return;
    }
    status = "MCP AUTH REQUIRED";
    message = exitCode === 127 || exitCode === -2
      ? "secret-tool is required to read the Homepage MCP token."
      : "Could not access Secret Service for the Homepage MCP token.";
    _checking = false;
  }

  function listTools(cycle, token) {
    const id = ++_requestId;
    request(cycle, token, JSON.stringify(Mcp.rpcRequest(id, "tools/list", {})), function(result) {
      if (!result.ok) { fail(cycle, result.httpStatus, result.error, Boolean(token)); return; }
      const parsed = Mcp.parseRpcResponse(result.body, id);
      const toolsResult = parsed.ok ? Mcp.parseTools(parsed.result) : parsed;
      if (!toolsResult.ok) { fail(cycle, 200, toolsResult.error, Boolean(token)); return; }
      tools = toolsResult.names;
      authenticated = Boolean(token);
      readEnabled = Mcp.supportsTool(tools, "read_config_file");
      serverWriteAvailable = false;
      writeEnabled = false;
      if (!authenticated) {
        status = "MCP AUTH REQUIRED";
        message = "Store the Homepage MCP token in Secret Service to use MCP.";
        _checking = false;
        return;
      }
      if (!readEnabled) {
        status = "MCP READ ONLY";
        message = "Homepage MCP does not advertise read_config_file. OmaHomepage remains read-only.";
        _checking = false;
        return;
      }
      if (!Mcp.supportsTool(tools, "list_config_files")) {
        finishWriteCapabilityCheck(cycle, false, "Homepage MCP cannot report its services.yaml write permission.");
        return;
      }
      callRawTool(cycle, "list_config_files", {}, function(configResult) {
        if (!current(cycle)) return;
        if (!configResult.ok) {
          finishWriteCapabilityCheck(cycle, false, "Homepage write permission could not be verified.");
          return;
        }
        const parsed = Mcp.parseRpcResponse(configResult.body, configResult.id);
        const config = parsed.ok ? Mcp.parseWritableConfigFiles(parsed.result) : parsed;
        finishWriteCapabilityCheck(cycle, config.ok && config.writable === true &&
          Mcp.supportsTool(tools, "add_service") && Mcp.supportsTool(tools, "write_config_file"),
          config.ok ? "" : "Homepage write permission could not be verified.");
      });
    });
  }

  function finishWriteCapabilityCheck(cycle, writable, explanation) {
    if (!current(cycle)) return;
    serverWriteAvailable = writable === true;
    writeEnabled = Mcp.writeGatesOpen(serverWriteAvailable, cycle.editingEnabled, authenticated);
    status = writeEnabled ? "MCP WRITE ENABLED" : "MCP READ ONLY";
    const advertised = Mcp.capabilitySummary(tools);
    message = (writeEnabled
      ? "Both Homepage write permission and OmaHomepage editing are enabled. "
      : "Writes require both Homepage write permission and editingEnabled in OmaHomepage. ")
      + (explanation ? explanation + " " : "")
      + "Detected: " + (advertised.length ? advertised.join(", ") : "no supported tools") + ".";
    _checking = false;
  }

  function request(cycle, token, body, callback) {
    if (!current(cycle)) return;
    if (token && cycle.origin.indexOf("https://") !== 0) {
      callback({ ok: false, httpStatus: 0, error: "Homepage MCP credentials require HTTPS." });
      return;
    }
    var settled = false;
    function finish(result) {
      if (settled) return;
      settled = true;
      if (_requestCancelCallback === cancelRequest) _requestCancelCallback = null;
      result.requestStarted = requestStarted;
      callback(result);
    }
    var cancelRequest = function() {
      finish({ ok: false, httpStatus: 0, error: "Homepage MCP request cancelled because its configuration changed." });
    };
    var requestStarted = false;
    _requestCancelCallback = cancelRequest;
    _requestCallback = function(id, exitCode, statusCode, contentType, responseBody, errorKind, errorMessage) {
      if (settled) return;
      if (!current(cycle)) {
        finish({ ok: false, httpStatus: 0, error: "Homepage MCP request cancelled because its configuration changed." });
        return;
      }
      if (exitCode !== 0) {
        finish({ ok: false, httpStatus: 0, error: errorMessage || "Homepage MCP request failed." });
        return;
      }
      if (statusCode !== 200) {
        const msg = statusCode === 404 ? "Homepage MCP is unavailable or disabled."
          : statusCode === 401 || statusCode === 403 ? (token ? "Homepage MCP authentication failed." : "Homepage MCP requires a token.")
          : statusCode >= 300 && statusCode < 400 ? "Homepage MCP redirects were rejected."
          : "Homepage MCP returned HTTP " + statusCode + ".";
        finish({ ok: false, httpStatus: statusCode, error: msg });
        return;
      }
      if (contentType !== "application/json" && !contentType.endsWith("+json")) {
        finish({ ok: false, httpStatus: statusCode, error: "Homepage MCP returned a non-JSON response." });
        return;
      }
      finish({ ok: true, httpStatus: statusCode, body: responseBody });
    };
    const id = ++_requestId;
    if (!transport.start(id, {
      url: cycle.origin + cycle.mcpPath,
      method: "POST",
      body,
      token,
      caCertPath: cycle.caCertPath,
      timeoutSec: cycle.timeoutSec,
      maxBytes: Model.LIMITS.responseBytes
    })) {
      const handler = _requestCallback;
      _requestCallback = null;
      _requestCancelCallback = null;
      if (handler) handler(id, -1, 0, "", "", "busy", "An MCP request is already running.");
    } else requestStarted = true;
  }

  function handleTransportCompleted(requestId, exitCode, httpStatus, contentType, body, errorKind, errorMessage) {
    const callback = _requestCallback;
    _requestCallback = null;
    if (callback) callback(requestId, exitCode, httpStatus, contentType, body, errorKind, errorMessage);
  }

  function fail(cycle, httpStatus, error, hadToken) {
    if (!current(cycle)) return;
    _checking = false;
    writeEnabled = false;
    readEnabled = false;
    serverWriteAvailable = false;
    if (httpStatus === 404) status = "MCP UNAVAILABLE";
    else if (httpStatus === 401 || httpStatus === 403) status = hadToken ? "MCP AUTHENTICATION FAILED" : "MCP AUTH REQUIRED";
    else if (error && error.indexOf("TLS") !== -1) status = "MCP UNAVAILABLE";
    else status = "MCP ERROR";
    message = error || "Homepage MCP could not be checked.";
  }

  function callRawTool(cycle, name, args, callback) {
    if (!current(cycle) || !_token) { callback({ ok: false, error: "Homepage MCP authentication is required.", requestStarted: false }); return; }
    const id = ++_requestId;
    const toolRequest = Mcp.makeToolCall(id, name, args, Model.safeHttpUrl);
    if (!toolRequest) { callback({ ok: false, error: "The requested MCP tool or arguments are not allowed by OmaHomepage.", requestStarted: false }); return; }
    if (name === "read_config_file" && !Mcp.supportsTool(tools, name)) {
      callback({ ok: false, error: "Homepage does not advertise read_config_file.", requestStarted: false }); return;
    }
    if (name === "list_config_files" && !Mcp.supportsTool(tools, name)) {
      callback({ ok: false, error: "Homepage does not advertise list_config_files.", requestStarted: false }); return;
    }
    if (["add_service", "validate_config_file", "write_config_file"].indexOf(name) !== -1 &&
        (!currentEditingCycle() || !Mcp.supportsTool(tools, name))) {
      callback({ ok: false, error: "Both MCP write gates and the requested tool are required.", requestStarted: false }); return;
    }
    const requestBody = JSON.stringify(toolRequest);
    request(cycle, _token, requestBody, function(result) {
      if (!result.ok) { callback(result); return; }
      const parsed = Mcp.parseRpcResponse(result.body, id);
      if (!parsed.ok) { callback({ ok: false, httpStatus: 200, error: parsed.error, requestStarted: result.requestStarted }); return; }
      callback({ ok: true, httpStatus: 200, result: parsed.result, body: result.body, id, requestStarted: result.requestStarted });
    });
  }

  function currentReadCycle() {
    return _cycle && current(_cycle) && readEnabled && _token;
  }

  function currentEditingCycle() {
    return _cycle && current(_cycle) && _cycle.editingEnabled === true &&
      Mcp.writeGatesOpen(serverWriteAvailable, _cycle.editingEnabled, authenticated) && Boolean(_token);
  }

  function readServicesYaml(callback) {
    if (!currentReadCycle()) { callback({ ok: false, error: "Authenticated read-only Homepage MCP is required." }); return; }
    operationBusy = true;
    callRawTool(_cycle, "read_config_file", { file: "services.yaml" }, function(response) {
      if (!response.ok) { operationBusy = false; callback(response); return; }
      const text = Mcp.textFromToolResult(response.result);
      operationBusy = false;
      callback(text.ok ? { ok: true, content: text.text } : text);
    });
  }

  function addService(group, name, service, callback) {
    if (!Mcp.canStartWrite(serverWriteAvailable, _cycle && _cycle.editingEnabled, authenticated, operationBusy) || !current(_cycle)) {
      callback({ ok: false, error: "Both Homepage write permission and editingEnabled are required; no write was sent." }); return;
    }
    const cleanGroup = Model.cleanText(group, Model.LIMITS.groupName);
    const cleanName = Model.cleanText(name, Model.LIMITS.name);
    const safeHref = Model.safeHttpUrl(service && service.href, Model.LIMITS.href);
    if (!cleanGroup || !cleanName || !safeHref) {
      callback({ ok: false, error: "Enter a group, service name and a valid HTTP(S) link." });
      return;
    }
    operationBusy = true;
    const safeService = {
      href: safeHref,
      description: Model.cleanText(service.description, Model.LIMITS.description)
    };
    const icon = Model.cleanText(service.icon, Model.LIMITS.icon);
    if (icon) safeService.icon = icon;
    const cycle = _cycle;
    Mcp.addAndVerifyService(function(tool, args, done) {
      root.callRawTool(cycle, tool, args, done);
    }, { group: cleanGroup, name: cleanName, service: safeService }, function(result) {
      operationBusy = false;
      callback(result);
    });
  }

  CurlTransport {
    id: transport
    onCompleted: function(requestId, exitCode, httpStatus, contentType, body, errorKind, errorMessage) {
      root.handleTransportCompleted(requestId, exitCode, httpStatus, contentType, body, errorKind, errorMessage);
    }
  }

  Component {
    id: lookupComponent
    Process {
      id: secretLookup
      property var cycle: null
      property bool cancelled: false
      property bool didStart: false
      property string secretOutput: ""
      property string secretError: ""
      command: ["secret-tool", "lookup", "application", "omaops-homepage", "instance", cycle ? cycle.secretId : "default"]
      clearEnvironment: true
      environment: ({
        PATH: "/usr/bin:/bin",
        LANG: "C.UTF-8",
        LC_ALL: "C",
        DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || "",
        XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR") || ""
      })
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: secretLookup.secretOutput = text }
      stderr: StdioCollector { waitForEnd: true; onStreamFinished: secretLookup.secretError = text }
      onStarted: didStart = true
      onRunningChanged: {
        if (!running && !didStart && !cancelled) Qt.callLater(function() { root.finishLookup(cycle, -2, "", ""); });
        else if (!running && !didStart && cancelled) secretLookup.destroy();
      }
      onExited: function(exitCode) {
        const output = secretOutput;
        const error = secretError;
        secretOutput = "";
        secretError = "";
        if (root._lookup === secretLookup) root._lookup = null;
        if (!cancelled) root.finishLookup(cycle, exitCode, output, error);
        secretLookup.destroy();
      }
    }
  }
}
