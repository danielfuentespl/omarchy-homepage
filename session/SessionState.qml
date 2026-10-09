pragma Singleton

import QtQml

QtObject {
  id: root

  property bool draftActive: false
  property bool formOpen: false
  property bool editingEnabled: false
  property string group: ""
  property string name: ""
  property string href: ""
  property string description: ""
  property string icon: ""
  property string identityKey: ""

  function setIdentity(key) {
    const next = String(key || "")
    if (identityKey && identityKey !== next && draftActive) discardDraft()
    identityKey = next
  }

  function beginDraft() {
    if (!editingEnabled) return false
    if (!draftActive) {
      group = ""
      name = ""
      href = ""
      description = ""
      icon = ""
      draftActive = true
    }
    formOpen = true
    return true
  }

  function updateField(field, value) {
    if (!draftActive || ["group", "name", "href", "description", "icon"].indexOf(field) === -1) return
    const next = String(value || "")
    if (root[field] !== next) root[field] = next
  }

  function setEditing(value) {
    const next = value === true
    if (draftActive && !next) return false
    editingEnabled = next
    return true
  }

  function discardDraft() {
    draftActive = false
    formOpen = false
    group = ""
    name = ""
    href = ""
    description = ""
    icon = ""
    editingEnabled = false
  }
}
