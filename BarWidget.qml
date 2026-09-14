import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "acrogenesis.ai-account-switcher"

  readonly property var accountService: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property bool ready: accountService !== null
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = button
    target.hostWidget = root
    target.service = root.accountService
  }

  onBarChanged: injectPanel()
  onAccountServiceChanged: injectPanel()

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

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { if (root.ready) root.accountService.refresh() }
    function saveCurrent(name: string): string {
      if (!root.ready) return "service unavailable"
      root.accountService.importCurrent(name)
      return "started"
    }
    function switchAccount(accountId: string): string {
      if (!root.ready) return "service unavailable"
      root.accountService.switchAccount(accountId)
      return "started"
    }
    function launchSelected(): string {
      if (!root.ready) return "service unavailable"
      root.accountService.launchSelectedAccount()
      return "started"
    }
    function enableCommandSwitching(): string {
      if (!root.ready) return "service unavailable"
      root.accountService.enableCommandSwitching()
      return "started"
    }
    function status(): string {
      if (!root.ready) return "service unavailable"
      return "active=\"" + root.accountService.activeName + "\""
        + " accounts=" + root.accountService.accounts.length
        + " canSwitch=" + root.accountService.canSwitch
        + (root.accountService.lastError
          ? " error=\"" + root.accountService.lastError + "\"" : "")
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    dimmed: !root.ready || root.accountService.accounts.length === 0
    active: root.ready && root.accountService.lastError !== ""
    tooltipText: !root.ready ? "AI accounts unavailable"
      : "Claude · " + root.accountService.activeName
    onPressed: function(code) {
      if (code === Qt.MiddleButton && root.ready) root.accountService.refresh()
      else root.toggle()
    }
  }
}
