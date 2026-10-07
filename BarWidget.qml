import QtQuick
import qs.Commons
import qs.Ui
import "ServiceHost.js" as ServiceHost

BarWidget {
  id: root
  moduleName: "com.blogvirtualizado.omaops.homepage"
  readonly property var hostedService: ServiceHost.hostedService(bar)
  readonly property color stateColor: {
    if (!hostedService) return bar ? bar.foreground : Color.foreground
    if (hostedService.apiState === "ONLINE") return Color.accent
    if (["OFFLINE", "AUTH REQUIRED", "ERROR"].indexOf(hostedService.apiState) !== -1) return Color.urgent
    return bar ? bar.foreground : Color.foreground
  }

  function injectPanel() {
    const target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Binding {
    target: root.hostedService
    property: "settings"
    value: root.settings
    when: root.hostedService !== null
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "⌂"
    slotSize: Style.bar.statusSlot
    tooltipText: "OmaHomepage · " + (root.hostedService ? root.hostedService.apiState : "UNKNOWN")
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton && panelLoader.item) panelLoader.item.refresh()
      else root.togglePanel()
    }

    Text {
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: Style.space(1)
      text: "●"
      textFormat: Text.PlainText
      color: root.stateColor
      font.pixelSize: Style.font.caption
    }
  }
}
