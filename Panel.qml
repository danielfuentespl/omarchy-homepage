import QtQuick
import QtQuick.Dialogs as Dialogs
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "Model.js" as Model
import "ServiceHost.js" as ServiceHost

Ui.Panel {
  id: root
  moduleName: "com.blogvirtualizado.omaops.homepage"
  ipcTarget: "com.blogvirtualizado.omaops.homepage"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool popoutSwitchClosing: false
  property string searchText: ""
  property var expandedGroups: ({})
  property string notice: ""
  property bool configEditing: false
  property string configDraft: ""
  property bool tlsBusy: false
  property int tlsOperationId: 0
  property var tlsProcess: null
  property var tlsCertificate: null
  property string tlsNotice: ""
  property string tlsConfirmAction: ""
  property bool tlsConfirmOpen: false
  property bool removeTrustConfirmOpen: false
  property bool addServiceVisible: false
  property bool addConfirmOpen: false
  property string newGroup: ""
  property string newName: ""
  property string newHref: ""
  property string newDescription: ""
  property string newIcon: ""
  property bool advancedFieldsOpen: false
  property string newSiteMonitor: ""
  property string newServer: ""
  property string newContainer: ""
  property bool yamlEditorOpen: false
  property string yamlText: ""
  property string yamlOriginalText: ""
  property bool yamlHasOriginal: false
  property string yamlPendingContent: ""
  property bool yamlLoading: false
  property bool yamlConfirmOpen: false
  property bool yamlPendingRestore: false
  property bool restoreAvailable: false
  property double nowMs: Date.now()

  readonly property var barIdentity: hostWidget || root
  readonly property var hostedService: ServiceHost.hostedService(bar)
  readonly property var service: hostedService !== null ? hostedService : dummyService
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color stateColor: {
    if (service.apiState === "ONLINE") return Color.accent
    if (["OFFLINE", "AUTH REQUIRED", "ERROR"].indexOf(service.apiState) !== -1) return urgent
    return foreground
  }
  readonly property var visibleGroups: Model.filterGroups(service.serviceGroups || [], searchText)
  readonly property bool searching: searchText.trim() !== ""
  readonly property var displayRows: Model.displayRows(visibleGroups, searching, expandedGroups)
  readonly property int totalGroupCount: Model.countGroups(service.serviceGroups || [])
  readonly property int totalServiceCount: Model.countServices(service.serviceGroups || [])
  readonly property int matchingServiceCount: Model.countServices(visibleGroups)
  readonly property bool writeControlsReady: service.editingEnabled === true && service.mcpAuthenticated === true
      && service.mcpWriteEnabled === true && service.mcpBusy !== true
  readonly property string tlsAddress: configEditing ? configDraft : service.baseUrl
  readonly property string tlsOrigin: Model.originUrl(tlsAddress)
  readonly property bool tlsSettingsMatchOrigin: tlsOrigin !== "" &&
    String(setting("tlsTrustOrigin", "") || "").toLowerCase() === tlsOrigin
  readonly property string tlsTrustMode: tlsSettingsMatchOrigin ? String(setting("tlsTrustMode", "system") || "system") : "system"
  readonly property string tlsTrustFingerprint: tlsSettingsMatchOrigin ? String(setting("tlsTrustFingerprint", "") || "").toLowerCase() : ""
  readonly property string effectiveTlsCaPath: Model.effectiveCaCertPath(tlsAddress, setting("caCertPath", ""), setting("tlsTrustOrigin", ""))
  readonly property bool certificateChanged: tlsCertificate && tlsTrustMode === "self-signed" &&
    (tlsCertificate.fingerprintHex || String(tlsCertificate.fingerprint || "").replace(/:/g, "").toLowerCase()) &&
    tlsTrustFingerprint && (tlsCertificate.fingerprintHex || String(tlsCertificate.fingerprint || "").replace(/:/g, "").toLowerCase()) !== tlsTrustFingerprint

  function toggleGroup(path, expanded) {
    if (searching) return
    const next = ({})
    for (const key in expandedGroups) next[key] = expandedGroups[key]
    next[path] = !expanded
    expandedGroups = next
  }

  QtObject {
    id: dummyService
    property string apiState: "NOT CONFIGURED"
    property string apiMessage: "The Homepage service is unavailable."
    property string baseUrl: ""
    property string mcpStatus: "MCP UNAVAILABLE"
    property string mcpMessage: ""
    property bool mcpWriteEnabled: false
    property bool mcpAuthenticated: false
    property bool mcpBusy: false
    property bool editingEnabled: false
    property bool refreshing: false
    property var serviceGroups: []
    property var services: []
    property date lastUpdated: new Date(0)
    function refresh() {}
    function refreshIfStale() {}
    function checkMcp() {}
    function checkMcpIfStale() {}
    function addService(group, name, spec, callback) { callback({ ok: false, error: "Homepage service is unavailable." }); }
    function readServicesYaml(callback) { callback({ ok: false, error: "Homepage service is unavailable." }); }
    function validateServicesYaml(content, callback) { callback({ ok: false, error: "Homepage service is unavailable." }); }
    function writeServicesYaml(content, callback) { callback({ ok: false, error: "Homepage service is unavailable." }); }
  }

  function setCenterHoverRevealSuppressed(value) {
    if (bar && typeof bar.setCenterHoverRevealSuppressed === "function") bar.setCenterHoverRevealSuppressed(value)
  }

  function open() {
    setCenterHoverRevealSuppressed(false)
    controller.show()
    service.refreshIfStale()
    service.checkMcpIfStale()
    if (!service.baseUrl) beginConfigEditing()
    else Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function openFromHotkey() {
    controller.show()
    service.refreshIfStale()
    service.checkMcpIfStale()
    if (!service.baseUrl) beginConfigEditing()
    else Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    controller.hide()
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  function toggle() { opened ? close() : openFromHotkey() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function setting(name, fallback) {
    const value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function beginConfigEditing() {
    notice = ""
    configDraft = String(setting("baseUrl", "") || "")
    configEditing = true
    Qt.callLater(function() { baseUrlInput.forceActiveFocus(); baseUrlInput.selectAll() })
  }

  function saveSetting(name, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") {
      notice = "This Omarchy version cannot save plugin settings. Update Omarchy and try again."
      return false
    }
    const entry = { id: moduleName }
    for (const key in settings) if (key !== "id") entry[key] = settings[key]
    const normalizedAddress = Model.normalizeBaseUrl(tlsAddress)
    if (normalizedAddress.ok) entry.baseUrl = normalizedAddress.value
    entry[name] = value
    const changed = bar.shell.updateEntryInline(moduleName, entry)
    if (!changed && String(setting(name, "")) !== String(value)) {
      notice = "Could not save the OmaHomepage setting."
      return false
    }
    settings = entry
    if (hostedService) hostedService.settings = entry
    configEditing = false
    return true
  }

  function saveTlsTrust(path, mode, fingerprint) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") {
      notice = "This Omarchy version cannot save plugin settings. Update Omarchy and try again."
      return false
    }
    const entry = { id: moduleName }
    for (const key in settings) if (key !== "id") entry[key] = settings[key]
    const normalizedAddress = Model.normalizeBaseUrl(tlsAddress)
    if (normalizedAddress.ok) entry.baseUrl = normalizedAddress.value
    entry.caCertPath = path || ""
    entry.tlsTrustMode = mode || "system"
    entry.tlsTrustOrigin = mode && mode !== "system" ? tlsOrigin : ""
    entry.tlsTrustFingerprint = fingerprint || ""
    const changed = bar.shell.updateEntryInline(moduleName, entry)
    const matches = ["baseUrl", "caCertPath", "tlsTrustMode", "tlsTrustOrigin", "tlsTrustFingerprint"]
      .every(function(key) { return String(setting(key, "")) === String(entry[key] || "") })
    if (!changed && !matches) {
      notice = "Could not save the OmaHomepage trust setting."
      return false
    }
    settings = entry
    if (hostedService) hostedService.settings = entry
    configEditing = false
    return true
  }

  function cancelTlsOperation() {
    tlsOperationId++
    if (tlsProcess) {
      const process = tlsProcess
      tlsProcess = null
      process.running = false
      process.destroy()
    }
    tlsBusy = false
  }

  function runTlsHelper(action, extraArgs) {
    const normalized = Model.normalizeBaseUrl(tlsAddress)
    if (!normalized.ok || normalized.value.indexOf("https://") !== 0) {
      tlsNotice = "Certificate inspection and custom trust require an HTTPS address."
      return false
    }
    cancelTlsOperation()
    const id = ++tlsOperationId
    const args = [action, normalized.value].concat(extraArgs || [])
    const process = tlsHelperComponent.createObject(root, {
      operationId: id,
      operation: action,
      operationOrigin: Model.originUrl(normalized.value),
      helperArgs: args,
      running: true
    })
    if (!process) {
      tlsNotice = "Could not start the local certificate inspection helper."
      return false
    }
    tlsProcess = process
    tlsBusy = true
    tlsNotice = action === "inspect" ? "Inspecting the unverified TLS certificate without sending an HTTP request…"
      : action === "import-ca" ? "Verifying the selected CA against this server…"
      : action === "remove-trust" ? "Removing OmaHomepage's local certificate copy…"
      : "Verifying the self-signed certificate…"
    return true
  }

  function finishTlsHelper(process, exitCode) {
    if (tlsProcess === process) tlsProcess = null
    tlsBusy = false
    if (process.operationId !== tlsOperationId || process.operationOrigin !== tlsOrigin) {
      process.destroy()
      return
    }
    let parsed = null
    try { parsed = JSON.parse(process.stdoutText || "") } catch (error) {}
    const action = process.operation
    process.destroy()
    if (!parsed || parsed.ok !== true) {
      tlsCertificate = action === "inspect" && parsed ? parsed : tlsCertificate
      tlsNotice = parsed && parsed.message ? parsed.message : "Certificate operation failed. No trust setting was changed."
      if (action === "inspect" && certificateChanged) tlsNotice = "Certificate changed. The new certificate is blocked; inspect it before replacing local trust."
      return
    }
    if (action === "inspect") {
      tlsCertificate = parsed
      tlsNotice = parsed.message || "Certificate inspection complete."
      if ((parsed.kind === "SYSTEM TRUST" || parsed.kind === "CUSTOM CA") && Model.originUrl(service.baseUrl) === tlsOrigin) service.refresh()
      else if (parsed.kind === "SYSTEM TRUST" || parsed.kind === "CUSTOM CA") tlsNotice = "TLS verified for this address. Save it to load services."
      if (certificateChanged) tlsNotice = "Certificate changed. The new certificate is blocked; inspect it before replacing local trust."
      return
    }
    if (action === "import-ca" || action === "trust-self-signed") {
      if (saveTlsTrust(parsed.caPath,
          action === "import-ca" ? "custom-ca" : "self-signed",
          action === "import-ca" ? tlsCertificate.fingerprintHex : parsed.fingerprint)) {
        tlsCertificate = null
        tlsNotice = action === "import-ca" ? "Private CA verified and imported for this Homepage origin." : "Self-signed certificate trusted for this Homepage origin."
        service.refresh()
      }
      return
    }
    if (action === "remove-trust") {
      if (saveTlsTrust("", "system", "")) {
        tlsCertificate = null
        tlsNotice = "OmaHomepage local trust removed. System trust will be used."
        service.refresh()
      }
    }
  }

  function testTlsConnection() {
    if (Model.originUrl(service.baseUrl) === tlsOrigin) service.refresh()
    runTlsHelper("inspect", effectiveTlsCaPath ? [effectiveTlsCaPath] : [])
  }

  function inspectCertificate() {
    runTlsHelper("inspect", effectiveTlsCaPath ? [effectiveTlsCaPath] : [])
  }

  function beginCertificateTrust(replace) {
    if (!tlsCertificate || !tlsCertificate.selfSigned || !tlsCertificate.ok ||
        tlsCertificate.kind !== "SELF-SIGNED TRUST AVAILABLE" && !replace ||
        !tlsCertificate.host || !(tlsCertificate.fingerprintHex || tlsCertificate.fingerprint) || certificateChanged !== replace) return
    tlsConfirmAction = replace ? "replace" : "trust"
    tlsConfirmOpen = true
  }

  function confirmCertificateTrust() {
    const replace = tlsConfirmAction === "replace"
    tlsConfirmOpen = false
    tlsConfirmAction = ""
    if (!tlsCertificate || !tlsCertificate.ok || !tlsCertificate.selfSigned || certificateChanged !== replace) return
    runTlsHelper("trust-self-signed", [tlsCertificate.fingerprintHex])
  }

  function removeCustomTrust() {
    removeTrustConfirmOpen = false
    const path = String(setting("caCertPath", "") || "")
    if (path.indexOf("/.config/omaops/homepage/trust/") !== -1) runTlsHelper("remove-trust", [path])
    else if (saveTlsTrust("", "system", "")) {
      tlsCertificate = null
      tlsNotice = "Custom trust removed from OmaHomepage settings."
      service.refresh()
    }
  }

  function selectedCaFile(path) {
    if (!path) return
    runTlsHelper("import-ca", [path])
  }

  function openCaPicker() {
    const normalized = Model.normalizeBaseUrl(tlsAddress)
    if (!normalized.ok || normalized.value.indexOf("https://") !== 0) {
      tlsNotice = "Set an HTTPS Homepage address before importing a CA."
      return
    }
    caFileDialog.open()
  }

  function saveBaseUrl() {
    const normalized = Model.normalizeBaseUrl(configDraft)
    if (!normalized.ok) { notice = normalized.error; baseUrlInput.forceActiveFocus(); return }
    if (saveSetting("baseUrl", normalized.value)) {
      configEditing = false
      notice = "Homepage address saved."
      service.refresh()
      service.checkMcp()
    }
  }

  function openUrl(raw) {
    const safe = Model.safeHttpUrl(raw)
    if (safe) Qt.openUrlExternally(safe)
    else notice = "This service does not have a safe HTTP(S) link."
  }

  function openYamlEditor() {
    if (!writeControlsReady) return
    notice = "Loading services.yaml from Homepage MCP…"
    yamlLoading = true
    service.readServicesYaml(function(result) {
      yamlLoading = false
      if (!result.ok) { notice = result.error; return }
      yamlText = result.content
      yamlOriginalText = result.content
      yamlHasOriginal = true
      yamlPendingContent = ""
      restoreAvailable = false
      yamlEditorOpen = true
      notice = "Edit services.yaml. OmaHomepage will validate it before saving."
    })
  }

  function closeYamlEditor() {
    if (yamlLoading) return
    yamlConfirmOpen = false
    yamlPendingContent = ""
    yamlPendingRestore = false
    yamlEditorOpen = false
    yamlText = ""
    yamlOriginalText = ""
    yamlHasOriginal = false
    restoreAvailable = false
  }

  function saveYaml() {
    if (!writeControlsReady || yamlLoading) return
    const candidate = yamlPendingRestore ? yamlOriginalText : yamlText
    if (typeof candidate !== "string" || candidate.length > 512 * 1024) {
      notice = "services.yaml exceeds the size limit."
      return
    }
    notice = "Validating services.yaml…"
    yamlLoading = true
    service.validateServicesYaml(candidate, function(result) {
      yamlLoading = false
      if (!result.ok || !result.valid) {
        notice = validationMessage(result, "Homepage rejected the YAML.")
        yamlPendingRestore = false
        return
      }
      yamlPendingContent = candidate
      yamlConfirmOpen = true
      notice = "Homepage validated the YAML. Confirm to send it to Homepage."
    })
  }

  function validationMessage(result, fallback) {
    const mark = result && result.mark && typeof result.mark.line === "number"
      ? " (line " + result.mark.line + (typeof result.mark.column === "number" ? ", column " + result.mark.column : "") + ")" : ""
    return (result && result.error || fallback) + mark
  }

  function cancelYamlConfirmation() {
    yamlConfirmOpen = false
    yamlPendingContent = ""
    yamlPendingRestore = false
  }

  function confirmYamlSave() {
    if (!yamlConfirmOpen || !writeControlsReady || yamlLoading) return
    const candidate = yamlPendingContent
    const restoring = yamlPendingRestore
    yamlConfirmOpen = false
    yamlPendingContent = ""
    yamlPendingRestore = false
    yamlLoading = true
    notice = restoring ? "Restoring the previous services.yaml snapshot…" : "Saving services.yaml and verifying it…"
    service.writeServicesYaml(candidate, function(result) {
      yamlLoading = false
      notice = result.ok ? result.message : validationMessage(result, "Homepage could not save services.yaml.")
      if (result.ok) {
        restoreAvailable = false
        yamlOriginalText = candidate
        yamlHasOriginal = true
      } else if (result.writeMayHaveChanged === true && !restoring && yamlHasOriginal) {
        restoreAvailable = true
        notice += " The write may have changed Homepage; you can explicitly restore the version read when editing began."
      } else if (result.writeMayHaveChanged === true && restoring) {
        restoreAvailable = true
        notice += " Restoration could not be verified; do not retry automatically."
      }
    })
  }

  function beginRestore() {
    if (!restoreAvailable || !yamlHasOriginal || !writeControlsReady || yamlLoading) return
    yamlPendingRestore = true
    saveYaml()
  }

  function addService() {
    if (!writeControlsReady || service.mcpBusy) return
    addConfirmOpen = true
  }

  function cancelAddConfirmation() {
    addConfirmOpen = false
  }

  function confirmAddService() {
    if (!addConfirmOpen || !writeControlsReady || service.mcpBusy) return
    addConfirmOpen = false
    notice = "Adding service and verifying it from Homepage…"
    service.addService(newGroup, newName, {
      href: newHref,
      description: newDescription,
      icon: newIcon,
      siteMonitor: newSiteMonitor,
      server: newServer,
      container: newContainer
    }, function(result) {
      notice = result.ok ? result.message : result.error
      if (!result.ok && result.writeMayHaveChanged === true) {
        notice += " The request may have changed Homepage; check the service list before trying again."
      }
      if (result.ok) {
        addServiceVisible = false
        newName = ""
        newHref = ""
        newDescription = ""
        newIcon = ""
        newSiteMonitor = ""
        newServer = ""
        newContainer = ""
        advancedFieldsOpen = false
      }
    })
  }

  Binding {
    target: root.hostedService
    property: "settings"
    value: root.settings
    when: root.hostedService !== null
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    service.refreshIfStale()
    service.checkMcpIfStale()
    if (!service.baseUrl) beginConfigEditing()
  }
  onConfigDraftChanged: {
    if (tlsBusy) cancelTlsOperation()
    tlsCertificate = null
    tlsNotice = ""
  }
  onSettingsChanged: {
    if (tlsBusy) cancelTlsOperation()
    tlsCertificate = null
    tlsNotice = ""
  }
  Component.onDestruction: cancelTlsOperation()

  Timer {
    interval: 10000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: "com.blogvirtualizado.omaops.homepage"
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.service.refresh() }
  }

  Component {
    id: tlsHelperComponent
    Process {
      id: tlsHelperProcess
      property int operationId: 0
      property string operation: ""
      property string operationOrigin: ""
      property var helperArgs: []
      property string stdoutText: ""
      command: ["/usr/bin/python3", Qt.resolvedUrl("scripts/certificate_helper.py").toString().replace(/^file:\/\//, "")].concat(helperArgs)
      clearEnvironment: true
      environment: ({ PATH: "/usr/bin:/bin", LANG: "C.UTF-8", LC_ALL: "C" })
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: tlsHelperProcess.stdoutText = text }
      onExited: function(exitCode) { root.finishTlsHelper(tlsHelperProcess, exitCode) }
    }
  }

  Ui.KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Keep the native KeyboardPanel anchor tied to the clicked bar widget.
    // centerOnBar places the card at the monitor center regardless of section.
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(650))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(680))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: baseUrlInput.activeFocus || searchField.activeFocus || addGroupInput.activeFocus || newNameInput.activeFocus
        || newHrefInput.activeFocus || newDescriptionInput.activeFocus || newIconInput.activeFocus
        || newSiteMonitorInput.activeFocus || newServerInput.activeFocus || newContainerInput.activeFocus
        || yamlInput.activeFocus
      onCloseRequested: {
        if (root.tlsConfirmOpen) { root.tlsConfirmOpen = false; root.tlsConfirmAction = "" }
        else if (root.removeTrustConfirmOpen) root.removeTrustConfirmOpen = false
        else if (root.yamlConfirmOpen) root.cancelYamlConfirmation()
        else if (root.addConfirmOpen) root.cancelAddConfirmation()
        else root.close()
      }
      onReturnRequested: {
        if (root.tlsConfirmOpen) root.confirmCertificateTrust()
        else if (root.removeTrustConfirmOpen) root.removeCustomTrust()
        else if (root.yamlConfirmOpen) root.confirmYamlSave()
        else if (root.addConfirmOpen) root.confirmAddService()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(8)

        ColumnLayout {
          id: contentColumn
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(8)

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: "OmaHomepage"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: "● " + (root.service.apiState || "UNKNOWN")
              textFormat: Text.PlainText
              color: root.stateColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: root.service.baseUrl || "Homepage address not configured"
              textFormat: Text.PlainText
              elide: Text.ElideMiddle
              color: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              opacity: 0.8
            }
            Ui.Button { text: "Configure"; onClicked: root.beginConfigEditing() }
          }

          Ui.TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Search services…"
            text: root.searchText
            onTextChanged: root.searchText = text
          }

          Text {
            Layout.fillWidth: true
            text: root.totalGroupCount + " groups · " + root.totalServiceCount + " services" +
              (root.searching ? " · " + root.matchingServiceCount + " matches" : "")
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            Layout.fillWidth: true
            visible: root.service.apiState !== "ONLINE"
            text: root.service.apiMessage
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.stateColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: root.service.editingEnabled
                ? root.service.mcpStatus + (root.service.mcpMessage ? " · " + root.service.mcpMessage : "")
                : "MCP READ ONLY · Enable configuration editing in OmaHomepage plugin settings to opt in."
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: root.service.mcpStatus === "MCP AUTHENTICATION FAILED" ? root.urgent : root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.service.editingEnabled && root.service.mcpWriteEnabled
            text: "Homepage's MCP token can access other configuration, including custom.js. Writes below are limited by this panel to services.yaml."
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Flickable {
            id: resultsFlickable
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: Style.space(120)
            Layout.preferredHeight: Style.space(360)
            contentWidth: width
            contentHeight: resultsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            ColumnLayout {
              id: resultsColumn
              width: resultsFlickable.width
              spacing: Style.space(5)

              Text {
                Layout.fillWidth: true
                visible: root.service.apiState === "ONLINE" && root.visibleGroups.length === 0
                text: root.searching ? "No services match this search." : "Homepage returned no services."
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
              }

              Repeater {
                model: root.displayRows
                delegate: Item {
                  required property var modelData
                  readonly property var serviceData: modelData.service ||
                    ({ name: "", status: "", description: "", linkAvailable: false, href: "" })
                  Layout.fillWidth: true
                  implicitHeight: groupButton.visible ? groupButton.implicitHeight : serviceCard.implicitHeight

                  Ui.Button {
                    id: groupButton
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: modelData.type === "group"
                    text: "\u00a0".repeat(modelData.depth * 2) +
                      (modelData.expanded ? "▾ " : "▸ ") + modelData.name + " · " + modelData.count
                    enabled: modelData.type === "group" && modelData.expandable === true && !root.searching
                    onClicked: root.toggleGroup(modelData.path, modelData.expanded)
                  }

                  Rectangle {
                    id: serviceCard
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: modelData.type === "service"
                    implicitHeight: serviceColumn.implicitHeight + Style.space(8)
                    radius: Math.min(4, Style.cornerRadius)
                    color: root.bar ? root.bar.background : Color.popups.background

                    RowLayout {
                      anchors.fill: parent
                      anchors.margins: Style.space(5)
                      spacing: Style.space(6)
                      Item { implicitWidth: Style.space(12) * modelData.depth }
                      ColumnLayout {
                        id: serviceColumn
                        Layout.fillWidth: true
                        spacing: Style.space(1)
                        Text {
                          Layout.fillWidth: true
                          text: serviceData.name +
                            (serviceData.status && serviceData.status !== "UNKNOWN" ? " · " + serviceData.status : "")
                          textFormat: Text.PlainText
                          elide: Text.ElideRight
                          color: root.foreground
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.body
                          font.bold: true
                        }
                        Text {
                          Layout.fillWidth: true
                          visible: serviceData.description !== ""
                          text: serviceData.description
                          textFormat: Text.PlainText
                          elide: Text.ElideRight
                          color: root.foreground
                          opacity: 0.75
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.bodySmall
                        }
                      }
                      Ui.Button {
                        text: "Open"
                        visible: serviceData.linkAvailable
                        enabled: serviceData.linkAvailable
                        onClicked: root.openUrl(serviceData.href)
                      }
                    }
                  }
                }
              }

          Rectangle {
            Layout.fillWidth: true
            visible: root.configEditing
            implicitHeight: configColumn.implicitHeight + Style.space(14)
            radius: Math.min(4, Style.cornerRadius)
            color: root.bar ? root.bar.background : Color.popups.background
            ColumnLayout {
              id: configColumn
              anchors.fill: parent
              anchors.margins: Style.space(8)
              Text { text: "Configure Homepage"; color: root.foreground; font.pixelSize: Style.font.heading; font.bold: true }
              Ui.TextField {
                id: baseUrlInput
                Layout.fillWidth: true
                placeholderText: "https://homepage.example.com"
                text: root.configDraft
                onTextChanged: root.configDraft = text
                onAccepted: root.saveBaseUrl()
              }
              Text {
                Layout.fillWidth: true
                text: "TLS · " + Model.tlsTrustStatus(root.tlsTrustMode)
                color: root.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              RowLayout {
                Layout.fillWidth: true
                Ui.Button { text: root.tlsBusy ? "Testing…" : "Test connection"; enabled: !root.tlsBusy; onClicked: root.testTlsConnection() }
                Ui.Button { text: "Inspect certificate"; enabled: !root.tlsBusy && root.tlsOrigin.indexOf("https://") === 0; onClicked: root.inspectCertificate() }
              }
              Text {
                Layout.fillWidth: true
                visible: root.tlsNotice !== ""
                text: root.tlsNotice
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                Layout.fillWidth: true
                visible: root.tlsCertificate !== null
                text: root.certificateChanged ? "Certificate changed · connection blocked" :
                  !root.tlsCertificate ? "" : root.tlsCertificate.kind === "PRIVATE_CA_REQUIRED" ? "TLS certificate not trusted · Private CA required" :
                  root.tlsCertificate.kind === "HOSTNAME_MISMATCH" ? "HOSTNAME MISMATCH · trust is blocked" :
                  root.tlsCertificate.kind === "CERTIFICATE_EXPIRED" ? "CERTIFICATE EXPIRED · trust is blocked" :
                  root.tlsCertificate.kind === "CERTIFICATE_NOT_YET_VALID" ? "CERTIFICATE NOT YET VALID · trust is blocked" :
                  root.tlsCertificate.kind === "SELF-SIGNED TRUST AVAILABLE" ? "Unverified certificate presented by server · self-signed signature and hostname verified" :
                  root.tlsCertificate.message || "Certificate inspection completed."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.tlsCertificate && (root.tlsCertificate.kind === "SYSTEM TRUST" || root.tlsCertificate.kind === "CUSTOM CA") ? root.foreground : root.urgent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              GridLayout {
                Layout.fillWidth: true
                visible: root.tlsCertificate !== null && Boolean(root.tlsCertificate.fingerprint || root.tlsCertificate.fingerprintHex)
                columns: 2
                Text { text: "Hostname"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.tlsCertificate ? root.tlsCertificate.host || "" : ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { text: "Subject"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.tlsCertificate ? root.tlsCertificate.subject || "" : ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { text: "Issuer"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.tlsCertificate ? root.tlsCertificate.issuer || "" : ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { text: "SAN"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.tlsCertificate && root.tlsCertificate.sans ? root.tlsCertificate.sans.join(", ") : ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { text: "Valid until"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.tlsCertificate ? root.tlsCertificate.validUntil || "" : ""; textFormat: Text.PlainText; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { text: "Valid from"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.tlsCertificate ? root.tlsCertificate.validFrom || "" : ""; textFormat: Text.PlainText; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { text: "SHA-256"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.tlsCertificate ? root.tlsCertificate.fingerprint || "" : ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.foreground; font.family: "monospace"; font.pixelSize: Style.font.caption }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.tlsCertificate && (root.tlsCertificate.kind === "PRIVATE_CA_REQUIRED" || root.tlsCertificate.kind === "CA_FILE_INVALID")
                Ui.Button { text: "Import CA certificate"; enabled: !root.tlsBusy; onClicked: root.openCaPicker() }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.tlsCertificate && root.tlsCertificate.kind === "SELF-SIGNED TRUST AVAILABLE" && !root.certificateChanged
                Ui.Button { text: "Trust this self-signed certificate"; enabled: !root.tlsBusy; onClicked: root.beginCertificateTrust(false) }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.certificateChanged
                Ui.Button { text: "Inspect new certificate"; enabled: !root.tlsBusy; onClicked: root.runTlsHelper("inspect", []) }
                Ui.Button { text: "Replace trust"; enabled: !root.tlsBusy && root.tlsCertificate && root.tlsCertificate.ok && root.tlsCertificate.selfSigned; onClicked: root.beginCertificateTrust(true) }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.tlsSettingsMatchOrigin && (root.tlsTrustMode === "custom-ca" || root.tlsTrustMode === "self-signed")
                Ui.Button { text: "Remove custom trust"; enabled: !root.tlsBusy; onClicked: root.removeTrustConfirmOpen = true }
              }
              RowLayout {
                Ui.Button { text: "Save address"; onClicked: root.saveBaseUrl() }
                Ui.Button { text: "Cancel"; onClicked: { root.cancelTlsOperation(); root.tlsCertificate = null; root.tlsNotice = ""; root.configEditing = false; root.notice = "" } }
              }
            }
          }

          Rectangle {
            Layout.fillWidth: true
            visible: root.addServiceVisible
            implicitHeight: addColumn.implicitHeight + Style.space(14)
            radius: Math.min(4, Style.cornerRadius)
            color: root.bar ? root.bar.background : Color.popups.background
            ColumnLayout {
              id: addColumn
              anchors.fill: parent
              anchors.margins: Style.space(8)
              Text { text: "Add Homepage service"; color: root.foreground; font.pixelSize: Style.font.heading; font.bold: true }
              Ui.TextField { id: addGroupInput; Layout.fillWidth: true; placeholderText: "Group"; text: root.newGroup; onTextChanged: root.newGroup = text }
              Ui.TextField { id: newNameInput; Layout.fillWidth: true; placeholderText: "Service name"; text: root.newName; onTextChanged: root.newName = text }
              Ui.TextField { id: newHrefInput; Layout.fillWidth: true; placeholderText: "http:// or https:// service address"; text: root.newHref; onTextChanged: root.newHref = text }
              Ui.TextField { id: newDescriptionInput; Layout.fillWidth: true; placeholderText: "Description (optional)"; text: root.newDescription; onTextChanged: root.newDescription = text }
              Ui.TextField { id: newIconInput; Layout.fillWidth: true; placeholderText: "Icon (optional)"; text: root.newIcon; onTextChanged: root.newIcon = text }
              Ui.Button { text: root.advancedFieldsOpen ? "Hide advanced fields" : "Advanced fields"; onClicked: root.advancedFieldsOpen = !root.advancedFieldsOpen }
              Ui.TextField { id: newSiteMonitorInput; Layout.fillWidth: true; visible: root.advancedFieldsOpen; placeholderText: "Site monitor URL (optional)"; text: root.newSiteMonitor; onTextChanged: root.newSiteMonitor = text }
              Ui.TextField { id: newServerInput; Layout.fillWidth: true; visible: root.advancedFieldsOpen; placeholderText: "Homepage Docker server (optional)"; text: root.newServer; onTextChanged: root.newServer = text }
              Ui.TextField { id: newContainerInput; Layout.fillWidth: true; visible: root.advancedFieldsOpen; placeholderText: "Container name (optional)"; text: root.newContainer; onTextChanged: root.newContainer = text }
              RowLayout {
                Ui.Button { text: root.service.mcpBusy ? "Adding…" : "Add service"; enabled: root.writeControlsReady; onClicked: root.addService() }
                Ui.Button { text: "Cancel"; enabled: !root.service.mcpBusy; onClicked: root.addServiceVisible = false }
              }
            }
          }

          Rectangle {
            Layout.fillWidth: true
            visible: root.yamlEditorOpen
            implicitHeight: yamlColumn.implicitHeight + Style.space(14)
            radius: Math.min(4, Style.cornerRadius)
            color: root.bar ? root.bar.background : Color.popups.background
            ColumnLayout {
              id: yamlColumn
              anchors.fill: parent
              anchors.margins: Style.space(8)
              Text { text: "services.yaml"; color: root.foreground; font.pixelSize: Style.font.heading; font.bold: true }
              Text {
                Layout.fillWidth: true
                text: "This text stays in memory in the panel. It is not written to local cache, logs or clipboard."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.pixelSize: Style.font.bodySmall
              }
              QQC.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(260)
                QQC.TextArea {
                  id: yamlInput
                  text: root.yamlText
                  onTextChanged: root.yamlText = text
                  font.family: "monospace"
                  wrapMode: TextEdit.NoWrap
                  selectByMouse: true
                  readOnly: root.yamlConfirmOpen || root.yamlLoading
                }
              }
              RowLayout {
                Ui.Button { text: root.yamlLoading ? "Working…" : "Validate & Save"; enabled: root.writeControlsReady && !root.yamlLoading; onClicked: root.saveYaml() }
                Ui.Button { text: "Restore previous version"; visible: root.restoreAvailable; enabled: root.writeControlsReady && !root.yamlLoading; onClicked: root.beginRestore() }
                Ui.Button { text: "Close"; enabled: !root.yamlLoading; onClicked: root.closeYamlEditor() }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.notice !== ""
            text: root.notice
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.notice.indexOf("failed") !== -1 || root.notice.indexOf("Could not") !== -1 ? root.urgent : root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            Ui.Button { text: "Refresh"; enabled: !root.service.refreshing; onClicked: { root.service.refresh(); root.service.checkMcpIfStale() } }
            Ui.Button {
              text: "+ Add service"
              enabled: root.writeControlsReady
              visible: root.writeControlsReady
              onClicked: { root.addServiceVisible = !root.addServiceVisible; root.yamlEditorOpen = false; root.notice = "" }
            }
            Ui.Button {
              text: "Edit services.yaml"
              enabled: root.writeControlsReady && !root.service.mcpBusy
              visible: root.writeControlsReady && !root.service.mcpBusy
              onClicked: { root.addServiceVisible = false; root.openYamlEditor() }
            }
            Item { Layout.fillWidth: true }
            Ui.Button { text: "Open Homepage"; enabled: Boolean(root.service.baseUrl); onClicked: root.openUrl(root.service.baseUrl) }
          }
        }
      }

      Ui.ConfirmDialog {
        anchors.fill: parent
        z: 10
        opened: root.addConfirmOpen
        message: "Add “" + Model.cleanText(root.newName, Model.LIMITS.name) + "” to “" + Model.cleanText(root.newGroup, Model.LIMITS.groupName) + "” at " + Model.safeHttpUrl(root.newHref) + "?"
        cancelText: "Cancel"
        confirmText: "Add service"
        background: root.bar ? root.bar.background : Color.popups.background
        foreground: root.foreground
        selectedText: Color.accent
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onCanceled: root.cancelAddConfirmation()
        onConfirmed: root.confirmAddService()
      }

      Ui.ConfirmDialog {
        anchors.fill: parent
        z: 11
        opened: root.yamlConfirmOpen
        message: root.yamlPendingRestore
          ? "Verification failed after a write. Restore the previous services.yaml snapshot? This may overwrite newer Homepage edits."
          : "Homepage validated services.yaml. Replace the current file? The YAML will be sent to Homepage and may contain credentials."
        cancelText: "Cancel"
        confirmText: root.yamlPendingRestore ? "Restore previous" : "Write services.yaml"
        background: root.bar ? root.bar.background : Color.popups.background
        foreground: root.foreground
        selectedText: Color.accent
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onCanceled: root.cancelYamlConfirmation()
        onConfirmed: root.confirmYamlSave()
      }

      Ui.ConfirmDialog {
        anchors.fill: parent
        z: 12
        opened: root.tlsConfirmOpen
        message: (root.tlsConfirmAction === "replace" ? "Replace this host's previous trust? The old fingerprint was " + root.tlsTrustFingerprint + ".\n\n" : "Trust this certificate only for: ") +
          (root.tlsCertificate ? root.tlsCertificate.host + "\nSubject: " + root.tlsCertificate.subject + "\nIssuer: " + root.tlsCertificate.issuer + "\nValid: " + root.tlsCertificate.validFrom + " — " + root.tlsCertificate.validUntil + "\nSHA-256: " + (root.tlsCertificate.fingerprint || "") : "") +
          (root.tlsConfirmAction === "replace" ? "\n\nPresented fingerprint: " + (root.tlsCertificate ? root.tlsCertificate.fingerprint || "" : "") : "")
        cancelText: "Cancel"
        confirmText: root.tlsConfirmAction === "replace" ? "Replace trust" : "Trust"
        background: root.bar ? root.bar.background : Color.popups.background
        foreground: root.foreground
        selectedText: Color.accent
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onCanceled: { root.tlsConfirmOpen = false; root.tlsConfirmAction = "" }
        onConfirmed: root.confirmCertificateTrust()
      }

      Ui.ConfirmDialog {
        anchors.fill: parent
        z: 13
        opened: root.removeTrustConfirmOpen
        message: "Remove OmaHomepage's local TLS trust for " + (root.tlsCertificate ? root.tlsCertificate.host : root.tlsOrigin) + "? System trust will be used afterward."
        cancelText: "Cancel"
        confirmText: "Remove trust"
        background: root.bar ? root.bar.background : Color.popups.background
        foreground: root.foreground
        selectedText: Color.accent
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onCanceled: root.removeTrustConfirmOpen = false
        onConfirmed: root.removeCustomTrust()
      }
    }
  }

  Dialogs.FileDialog {
    id: caFileDialog
    title: "Select a public CA certificate"
    fileMode: Dialogs.FileDialog.OpenFile
    nameFilters: ["PEM certificates (*.pem *.crt *.cer)", "All files (*)"]
    onAccepted: root.selectedCaFile(selectedFile.toLocalFile())
  }
}
