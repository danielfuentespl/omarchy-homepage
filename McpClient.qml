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
  property var _lookup: null
  property bool _checking: false

  function configurationKey(spec) {
    return JSON.stringify([spec.baseUrl, spec.secretId, spec.caCertPath, spec.mcpPath, spec.editingEnabled]);
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
    var active = transport.activeProcess;
    if (active) transport.cancel(active.requestId);
    _requestCallback = null;
    _cycle = null;
    _token = "";
    _checking = false;
    operationBusy = false;
  }

  function reset() {
    cancel();
    _configKey = "";
    status = "MCP UNAVAILABLE";
    message = "";
    writeEnabled = false;
    authenticated = false;
    operationBusy = false;
    tools = [];
  }

  function current(cycle) {
    return cycle && cycle.generation === _generation && cycle.key === _configKey;
  }

  function check(spec) {
    cancel();
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
      mcpPath,
      secretId: spec.secretId || "default",
      caCertPath: spec.caCertPath || "",
      editingEnabled: spec.editingEnabled === true,
      timeoutSec: Math.max(1, Math.ceil(Number(spec.requestTimeoutMs || 8000) / 1000))
    };
    _checking = true;
    if (!_cycle.editingEnabled) {
      _checking = false;
      status = "MCP READ ONLY";
      message = "Editing is disabled in OmaHomepage; MCP is not contacted until you opt in.";
      writeEnabled = false;
      authenticated = false;
      return;
    }
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
      if (!authenticated) {
        status = "MCP AUTH REQUIRED";
        message = "Store the Homepage MCP token in Secret Service to use MCP.";
        writeEnabled = false;
        _checking = false;
        return;
      }
      if (tools.indexOf("list_config_files") === -1) {
        status = "MCP READ ONLY";
        message = "Homepage MCP does not expose config-file capability information.";
        writeEnabled = false;
        _checking = false;
        return;
      }
      callRawTool(cycle, "list_config_files", {}, function(configResult) {
        if (!configResult.ok) { fail(cycle, configResult.httpStatus, configResult.error, true); return; }
        const rpc = Mcp.parseRpcResponse(configResult.body, configResult.id);
        const access = rpc.ok ? Mcp.parseWritableConfigFiles(rpc.result) : rpc;
        if (!access.ok) { fail(cycle, 200, access.error, true); return; }
        writeEnabled = access.writable;
        status = writeEnabled ? "MCP WRITE ENABLED" : "MCP READ ONLY";
        message = writeEnabled
          ? "Homepage MCP allows writes. Use editing controls only after enabling them in OmaHomepage settings."
          : "Homepage MCP is authenticated and read-only.";
        _checking = false;
      });
    });
  }

  function request(cycle, token, body, callback) {
    if (!current(cycle)) return;
    if (token && cycle.origin.indexOf("https://") !== 0) {
      callback({ ok: false, httpStatus: 0, error: "Homepage MCP credentials require HTTPS." });
      return;
    }
    _requestCallback = function(id, exitCode, statusCode, contentType, responseBody, errorKind, errorMessage) {
      if (!current(cycle)) return;
      if (exitCode !== 0) {
        callback({ ok: false, httpStatus: 0, error: errorMessage || "Homepage MCP request failed." });
        return;
      }
      if (statusCode !== 200) {
        const msg = statusCode === 404 ? "Homepage MCP is unavailable or disabled."
          : statusCode === 401 || statusCode === 403 ? (token ? "Homepage MCP authentication failed." : "Homepage MCP requires a token.")
          : statusCode >= 300 && statusCode < 400 ? "Homepage MCP redirects were rejected."
          : "Homepage MCP returned HTTP " + statusCode + ".";
        callback({ ok: false, httpStatus: statusCode, error: msg });
        return;
      }
      if (contentType !== "application/json" && !contentType.endsWith("+json")) {
        callback({ ok: false, httpStatus: statusCode, error: "Homepage MCP returned a non-JSON response." });
        return;
      }
      callback({ ok: true, httpStatus: statusCode, body: responseBody });
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
      if (handler) handler(id, -1, 0, "", "", "busy", "An MCP request is already running.");
    }
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
    if (httpStatus === 404) status = "MCP UNAVAILABLE";
    else if (httpStatus === 401 || httpStatus === 403) status = hadToken ? "MCP AUTHENTICATION FAILED" : "MCP AUTH REQUIRED";
    else if (error && error.indexOf("TLS") !== -1) status = "MCP UNAVAILABLE";
    else status = "MCP ERROR";
    message = error || "Homepage MCP could not be checked.";
  }

  function callRawTool(cycle, name, args, callback) {
    if (!current(cycle) || !_token) { callback({ ok: false, error: "Homepage MCP authentication is required." }); return; }
    if (tools.indexOf(name) === -1) { callback({ ok: false, error: "Homepage does not support the requested MCP tool." }); return; }
    const id = ++_requestId;
    const requestBody = JSON.stringify(Mcp.makeToolCall(id, name, args));
    request(cycle, _token, requestBody, function(result) {
      if (!result.ok) { callback(result); return; }
      const parsed = Mcp.parseRpcResponse(result.body, id);
      if (!parsed.ok) { callback({ ok: false, httpStatus: 200, error: parsed.error }); return; }
      callback({ ok: true, httpStatus: 200, result: parsed.result, body: result.body, id });
    });
  }

  function currentEditingCycle() {
    return _cycle && current(_cycle) && _cycle.editingEnabled && writeEnabled && _token;
  }

  function readServicesYaml(callback) {
    if (!currentEditingCycle()) { callback({ ok: false, error: "Enable editing and authenticated Homepage MCP first." }); return; }
    operationBusy = true;
    callRawTool(_cycle, "read_config_file", { file: "services.yaml" }, function(response) {
      if (!response.ok) { operationBusy = false; callback(response); return; }
      const text = Mcp.textFromToolResult(response.result);
      operationBusy = false;
      callback(text.ok ? { ok: true, content: text.text } : text);
    });
  }

  function validateServicesYaml(content, callback) {
    if (!currentEditingCycle()) { callback({ ok: false, error: "Enable editing and authenticated write access first." }); return; }
    if (typeof content !== "string" || content.length > 512 * 1024) { callback({ ok: false, error: "services.yaml exceeds the size limit." }); return; }
    operationBusy = true;
    callRawTool(_cycle, "validate_config_file", { file: "services.yaml", content }, function(response) {
      if (!response.ok) { operationBusy = false; callback(response); return; }
      const validation = Mcp.parseValidation(response.result);
      operationBusy = false;
      callback(validation.ok ? validation : { ok: false, error: validation.error });
    });
  }

  function writeServicesYaml(content, callback) {
    if (!currentEditingCycle()) { callback({ ok: false, error: "Enable editing and authenticated write access first." }); return; }
    if (typeof content !== "string" || content.length > 512 * 1024) { callback({ ok: false, error: "services.yaml exceeds the size limit." }); return; }
    operationBusy = true;
    callRawTool(_cycle, "validate_config_file", { file: "services.yaml", content }, function(validationResult) {
      if (!validationResult.ok) { operationBusy = false; callback(validationResult); return; }
      const validation = Mcp.parseValidation(validationResult.result);
      if (!validation.ok || !validation.valid) {
        operationBusy = false;
        callback({ ok: false, error: validation.error || "services.yaml failed validation.", mark: validation.mark || null });
        return;
      }
      callRawTool(_cycle, "write_config_file", { file: "services.yaml", content }, function(written) {
        if (!written.ok) { operationBusy = false; callback(written); return; }
        const writtenText = Mcp.textFromToolResult(written.result);
        let confirmation;
        try { confirmation = writtenText.ok ? JSON.parse(writtenText.text) : null; } catch (_) { confirmation = null; }
        if (!confirmation || confirmation.written !== "services.yaml") {
          operationBusy = false;
          callback({ ok: false, error: "Homepage did not confirm writing services.yaml.", writeMayHaveChanged: true });
          return;
        }
        callRawTool(_cycle, "read_config_file", { file: "services.yaml" }, function(readback) {
          if (!readback.ok) { operationBusy = false; callback({ ok: false, error: readback.error, writeMayHaveChanged: true }); return; }
          const actual = Mcp.textFromToolResult(readback.result);
          operationBusy = false;
          callback(actual.ok && actual.text === content
            ? { ok: true, message: "services.yaml saved and verified by read-back." }
            : { ok: false, error: actual.ok ? "Read-back did not match the saved content." : actual.error, writeMayHaveChanged: true });
        });
      });
    });
  }

  function addService(group, name, service, callback) {
    if (!currentEditingCycle()) { callback({ ok: false, error: "Enable editing and authenticated write access first." }); return; }
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
    const siteMonitorInput = Model.cleanText(service.siteMonitor, Model.LIMITS.href);
    const siteMonitor = siteMonitorInput ? Model.safeHttpUrl(siteMonitorInput, Model.LIMITS.href) : "";
    const server = Model.cleanText(service.server, Model.LIMITS.metadata);
    const container = Model.cleanText(service.container, Model.LIMITS.metadata);
    if (siteMonitorInput && !siteMonitor) {
      operationBusy = false;
      callback({ ok: false, error: "Site monitor must be a safe HTTP(S) URL." });
      return;
    }
    if (icon) safeService.icon = icon;
    if (siteMonitor) safeService.siteMonitor = siteMonitor;
    if (server) safeService.server = server;
    if (container) safeService.container = container;
    callRawTool(_cycle, "add_service", { group: cleanGroup, name: cleanName, service: safeService }, function(response) {
      if (!response.ok) { operationBusy = false; callback(response); return; }
      const added = Mcp.parseAddService(response.result);
      if (!added.ok) { operationBusy = false; callback(added); return; }
      callRawTool(_cycle, "read_config_file", { file: "services.yaml" }, function(readback) {
        if (!readback.ok) { operationBusy = false; callback(readback); return; }
        const actual = Mcp.textFromToolResult(readback.result);
        operationBusy = false;
        callback(actual.ok && actual.text === added.content
          ? { ok: true, message: "Service added and verified by read-back." }
          : { ok: false, error: actual.ok ? "Service add read-back did not match the write." : actual.error });
      });
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
