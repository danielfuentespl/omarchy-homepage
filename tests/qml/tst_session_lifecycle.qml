import QtQuick
import QtTest
import "../../session" as OmaSession

TestCase {
  name: "OmaHomepageSessionLifecycle"

  Component {
    id: panelFixture
    QtObject {
      readonly property bool draftActive: OmaSession.SessionState.draftActive
      readonly property bool formOpen: OmaSession.SessionState.formOpen
      readonly property bool editingEnabled: OmaSession.SessionState.editingEnabled
      readonly property string group: OmaSession.SessionState.group
      readonly property string name: OmaSession.SessionState.name
      readonly property string href: OmaSession.SessionState.href
      readonly property string description: OmaSession.SessionState.description
      readonly property string icon: OmaSession.SessionState.icon
    }
  }

  function initTestCase() {
    compare(OmaSession.SessionState.draftActive, false)
    compare(OmaSession.SessionState.formOpen, false)
    compare(OmaSession.SessionState.editingEnabled, false)
  }

  function test_panelDestructionAndRecreationKeepsDraft() {
    OmaSession.SessionState.setEditing(true)
    verify(OmaSession.SessionState.beginDraft())
    OmaSession.SessionState.updateField("group", "Group fixture")
    OmaSession.SessionState.updateField("name", "Name fixture")
    OmaSession.SessionState.updateField("href", "https://example.invalid/service")
    OmaSession.SessionState.updateField("description", "Description fixture")
    OmaSession.SessionState.updateField("icon", "mdi-test-tube")
    verify(!OmaSession.SessionState.setEditing(false))
    compare(OmaSession.SessionState.editingEnabled, true)

    const firstPanel = panelFixture.createObject(this)
    verify(firstPanel)
    compare(firstPanel.group, "Group fixture")
    firstPanel.destroy()
    wait(0)

    const recreatedPanel = panelFixture.createObject(this)
    verify(recreatedPanel)
    compare(recreatedPanel.draftActive, true)
    compare(recreatedPanel.formOpen, true)
    compare(recreatedPanel.editingEnabled, true)
    compare(recreatedPanel.group, "Group fixture")
    compare(recreatedPanel.name, "Name fixture")
    compare(recreatedPanel.href, "https://example.invalid/service")
    compare(recreatedPanel.description, "Description fixture")
    compare(recreatedPanel.icon, "mdi-test-tube")
    recreatedPanel.destroy()
  }

  function test_identityChangeDiscardsDraftAndEditing() {
    OmaSession.SessionState.discardDraft()
    OmaSession.SessionState.setIdentity("https://one.example|default|system")
    OmaSession.SessionState.setEditing(true)
    verify(OmaSession.SessionState.beginDraft())
    OmaSession.SessionState.updateField("group", "Group fixture")
    OmaSession.SessionState.setIdentity("https://two.example|default|system")
    compare(OmaSession.SessionState.draftActive, false)
    compare(OmaSession.SessionState.formOpen, false)
    compare(OmaSession.SessionState.group, "")
    compare(OmaSession.SessionState.editingEnabled, false)
  }

  function test_discardClearsFieldsAndAuthorization() {
    OmaSession.SessionState.setEditing(true)
    verify(OmaSession.SessionState.beginDraft())
    OmaSession.SessionState.updateField("name", "Name fixture")
    OmaSession.SessionState.discardDraft()
    compare(OmaSession.SessionState.draftActive, false)
    compare(OmaSession.SessionState.formOpen, false)
    compare(OmaSession.SessionState.name, "")
    compare(OmaSession.SessionState.editingEnabled, false)
  }
}
