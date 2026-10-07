import QtQuick
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
  property string notice: ""
  property bool configEditing: false
  property string configDraft: ""
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
  readonly property var displayGroups: Model.flattenGroups(visibleGroups)
  readonly property bool writeControlsReady: service.editingEnabled === true && service.mcpAuthenticated === true
      && service.mcpWriteEnabled === true && service.mcpBusy !== true

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
    entry[name] = value
    const changed = bar.shell.updateEntryInline(moduleName, entry)
    if (!changed && String(setting(name, "")) !== String(value)) {
      notice = "Could not save the OmaHomepage setting."
      return false
    }
    settings = entry
    if (hostedService) hostedService.settings = entry
    return true
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

  Ui.KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(650))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: baseUrlInput.activeFocus || searchField.activeFocus || addGroupInput.activeFocus || newNameInput.activeFocus
        || newHrefInput.activeFocus || newDescriptionInput.activeFocus || newIconInput.activeFocus
        || newSiteMonitorInput.activeFocus || newServerInput.activeFocus || newContainerInput.activeFocus
        || yamlInput.activeFocus
      onCloseRequested: {
        if (root.yamlConfirmOpen) root.cancelYamlConfirmation()
        else if (root.addConfirmOpen) root.cancelAddConfirmation()
        else root.close()
      }
      onReturnRequested: {
        if (root.yamlConfirmOpen) root.confirmYamlSave()
        else if (root.addConfirmOpen) root.confirmAddService()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: contentColumn
          width: parent.width
          spacing: Style.space(10)

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

          Text {
            Layout.fillWidth: true
            visible: root.service.serviceGroups.length === 0 && root.service.apiState === "ONLINE"
            text: root.searchText ? "No services match this search." : "Homepage returned no services."
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.displayGroups
            delegate: ColumnLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.space(4)
              Text {
                Layout.fillWidth: true
                text: modelData.path
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Repeater {
                model: modelData.services
                delegate: Rectangle {
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: serviceRow.implicitHeight + Style.space(12)
                  radius: Math.min(4, Style.cornerRadius)
                  color: root.bar ? root.bar.background : Color.popups.background

                  RowLayout {
                    id: serviceRow
                    anchors.fill: parent
                    anchors.margins: Style.space(7)
                    spacing: Style.space(8)
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(2)
                      Text {
                        Layout.fillWidth: true
                        text: modelData.name + " · UNKNOWN"
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.foreground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        Layout.fillWidth: true
                        visible: modelData.description !== ""
                        text: modelData.description
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.foreground
                        opacity: 0.75
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        Layout.fillWidth: true
                        visible: modelData.dockerLinked
                        text: "Docker integration: " + (modelData.server || "default") +
                              (modelData.container ? " / " + modelData.container : "") +
                              " · Homepage API does not identify the service source"
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: root.foreground
                        opacity: 0.7
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                    Ui.Button {
                      text: "Open"
                      enabled: modelData.linkAvailable
                      onClicked: root.openUrl(modelData.href)
                    }
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
              RowLayout {
                Ui.Button { text: "Save address"; onClicked: root.saveBaseUrl() }
                Ui.Button { text: "Cancel"; onClicked: { root.configEditing = false; root.notice = "" } }
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

          RowLayout {
            Layout.fillWidth: true
            Ui.Button { text: "Refresh"; enabled: !root.service.refreshing; onClicked: { root.service.refresh(); root.service.checkMcpIfStale() } }
            Ui.Button {
              text: "+ Add service"
              enabled: root.writeControlsReady
              visible: root.service.editingEnabled
              onClicked: { root.addServiceVisible = !root.addServiceVisible; root.yamlEditorOpen = false; root.notice = "" }
            }
            Ui.Button {
              text: "Edit services.yaml"
              enabled: root.writeControlsReady && !root.service.mcpBusy
              visible: root.service.editingEnabled
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
    }
  }
}
