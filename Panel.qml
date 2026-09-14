import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "acrogenesis.ai-account-switcher"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property int cursorIndex: 0
  property bool cursorActive: false
  property bool configureOpen: false

  function open() {
    if (service) service.refresh(true)
    cursorIndex = 0
    cursorActive = false
    configureOpen = false
    controller.show()
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function moveCursor(direction) {
    if (!service || service.accounts.length === 0) return
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(service.accounts.length - 1, cursorIndex + direction))
  }

  function activateCursor() {
    if (!service || !cursorActive || cursorIndex >= service.accounts.length) return
    service.switchAccount(service.accounts[cursorIndex].id)
  }

  function usageSummary(usage) {
    if (!usage || usage.loading === true) return "Checking plan usage…"
    if (usage.available !== true || !Array.isArray(usage.windows) || usage.windows.length === 0)
      return String(usage.reason || "Usage unavailable")
    return usage.windows.map(function(window) {
      var remaining = Math.max(0, Math.round(100 - Number(window.used_percent || 0)))
      return String(window.label || "Limit").toUpperCase() + " " + remaining + "% left"
    }).join(" · ")
  }

  function usageResetSummary(usage) {
    if (!usage || !Array.isArray(usage.windows)) return ""
    var nextReset = 0
    var now = Date.now() / 1000
    for (var i = 0; i < usage.windows.length; i++) {
      var reset = Number(usage.windows[i].resets_at || 0)
      if (reset > now && (nextReset === 0 || reset < nextReset)) nextReset = reset
    }
    return nextReset > 0
      ? "Next reset " + Qt.formatDateTime(new Date(nextReset * 1000), "ddd h:mm AP") : ""
  }

  component UsageBar: Item {
    id: usageBar
    property var window: null
    readonly property real remainingPercent: Math.max(0,
      Math.min(100, 100 - Number(window ? window.used_percent || 0 : 0)))
    readonly property color fillColor: remainingPercent <= 10 ? root.urgent : root.accent

    implicitHeight: Style.space(20)

    Rectangle {
      id: usageTrack
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    }

    Rectangle {
      anchors.left: usageTrack.left
      anchors.top: usageTrack.top
      anchors.bottom: usageTrack.bottom
      width: usageTrack.width * usageBar.remainingPercent / 100
      radius: usageTrack.radius
      color: Qt.rgba(usageBar.fillColor.r, usageBar.fillColor.g, usageBar.fillColor.b, 0.72)

      Behavior on width {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.fill: parent
      text: String(usageBar.window ? usageBar.window.label || "Limit" : "Limit").toUpperCase()
        + " · " + Math.round(usageBar.remainingPercent) + "% LEFT"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nameField.activeFocus
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if ((text === "r" || text === "R") && root.service) root.service.refresh()
        else if ((text === "a" || text === "A") && root.service) root.service.addAnotherAccount()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero (not this Panel) — reach panel state via `header`.
            readonly property bool configureOpen: root.configureOpen
            function toggleConfigure() { root.configureOpen = !root.configureOpen }

            PanelHero {
              id: hero
              width: parent.width
              title: root.service
                ? "Claude · " + root.service.activeName
                : "Claude accounts"
              meta: !root.service ? "Service unavailable"
                : (root.service.runningCount > 0
                  ? root.service.runningCount + " active Claude session"
                    + (root.service.runningCount === 1 ? "" : "s")
                  : root.service.accounts.length + " saved account"
                    + (root.service.accounts.length === 1 ? "" : "s"))
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "󱚣"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                PanelActionButton {
                  iconText: "󰒓"
                  tooltipText: header.configureOpen ? "Hide settings" : "Settings"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  fontSize: Style.font.iconSmall
                  focusable: true
                  bordered: header.configureOpen
                  onClicked: header.toggleConfigure()
                }
              }
            }
          }

          BorderSurface {
            visible: root.service && root.service.lastError !== ""
            width: parent.width
            implicitHeight: errorText.implicitHeight + Style.space(20)
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: errorText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              text: root.service ? root.service.lastError : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: 4
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.service && root.service.lastError === "" && root.service.lastAction !== ""
            width: parent.width
            text: root.service ? root.service.lastAction : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "ACCOUNTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.service && root.service.accounts.length === 0
            width: parent.width
            text: !root.service ? ""
              : (root.service.hasCurrentLogin
                ? "Save the current Claude login below to start."
                : "Log in to Claude, then save that login here.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
          }

          Column {
            id: accountList
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.service ? root.service.accounts : []

              AccountRow {
                required property var modelData
                required property int index
                width: accountList.width
                account: modelData
                rowIndex: index
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: root.configureOpen

            PanelSeparator { width: parent.width; foreground: root.foreground }

            PanelSectionHeader {
              width: parent.width
              text: "SAVE CURRENT CLAUDE LOGIN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: nameField
                width: parent.width - saveButton.width - parent.spacing
                placeholderText: root.service && root.service.suggestedName
                  ? root.service.suggestedName : "Account name (optional)"
                maximumLength: 120
                foreground: root.foreground
                font.family: root.fontFamily
                enabled: root.service && root.service.hasCurrentLogin && !root.service.busy
                onAccepted: saveButton.clicked()
              }

              Button {
                id: saveButton
                text: root.service && root.service.currentSaved ? "Update" : "Save"
                foreground: root.foreground
                fontFamily: root.fontFamily
                focusable: true
                enabled: root.service && root.service.hasCurrentLogin && !root.service.busy
                onClicked: {
                  if (!root.service) return
                  root.service.importCurrent(nameField.text)
                  nameField.text = ""
                  keyCatcher.forceActiveFocus()
                }
              }
            }

            Button {
              width: parent.width
              text: root.service && root.service.activeAccountId !== ""
                ? "Open Claude as " + root.service.activeName
                : "Select a saved account to open Claude"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              enabled: root.service && root.service.activeAccountId !== ""
                && !root.service.busy && !root.service.launching
              onClicked: {
                root.close()
                root.service.launchSelectedAccount()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Each launched session keeps this account, even after you select another one."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Button {
              visible: root.service && !root.service.commandWrappersEnabled
              width: parent.width
              text: "Make the plain claude command follow selection"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              enabled: root.service && !root.service.busy
              onClicked: root.service.enableCommandSwitching()
            }

            Text {
              textFormat: Text.PlainText
              visible: root.service && root.service.commandWrappersEnabled
              width: parent.width
              text: "New plain claude processes also use the selected account."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              text: "Add another Claude account"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              enabled: root.service && !root.service.busy
              onClicked: {
                root.close()
                root.service.addAnotherAccount()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Runs an isolated official Claude login without disturbing active sessions."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Sessions opened from this panel use the selected login. Middle-click the bar icon to refresh."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null
    property int rowIndex: 0
    readonly property var usage: account && root.service
      ? root.service.usageFor(String(account.id || "")) : null
    readonly property bool currentAccount: account && account.is_active === true
    readonly property bool switching: account && root.service
      && root.service.switchingId === String(account.id || "")

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    current: currentAccount
    foreground: root.foreground
    accent: root.accent
    // Account selection already has a persistent fill and checkmark. A second
    // outlined row on hover makes both accounts look selected, so use only the
    // shared hover fill here.
    borderSpec: Border.none()
    implicitHeight: row.implicitHeight + Style.space(16)

    RowLayout {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: accountRow.switching ? "󰑓" : (accountRow.currentAccount ? "󰄬" : "󰀄")
        color: accountRow.currentAccount ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: accountRow.account ? String(accountRow.account.name || "Account") : "Account"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: accountRow.currentAccount
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: {
            if (!accountRow.account) return ""
            var pieces = []
            if (accountRow.account.email) pieces.push(accountRow.account.email)
            if (accountRow.account.subscription_type)
              pieces.push(String(accountRow.account.subscription_type).toUpperCase())
            if (accountRow.account.org_name) pieces.push(String(accountRow.account.org_name))
            if (accountRow.currentAccount) pieces.push("SELECTED")
            return pieces.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        RowLayout {
          visible: accountRow.usage && accountRow.usage.available === true
          Layout.fillWidth: true
          spacing: Style.space(6)

          Repeater {
            model: accountRow.usage && Array.isArray(accountRow.usage.windows)
              ? accountRow.usage.windows : []

            UsageBar {
              required property var modelData
              Layout.fillWidth: true
              window: modelData
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !accountRow.usage || accountRow.usage.available !== true
          Layout.fillWidth: true
          text: root.usageSummary(accountRow.usage)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          Layout.fillWidth: true
          text: root.usageResetSummary(accountRow.usage)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: root.service && !root.service.busy ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: root.service && !root.service.busy
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = accountRow.rowIndex
      }
      onClicked: if (accountRow.account) root.service.switchAccount(accountRow.account.id)
    }
  }
}
