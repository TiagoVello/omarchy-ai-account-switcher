import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string claudeStorePath: home + "/.config/omarchy/ai-account-switcher/claude-accounts.json"
  readonly property string helperPath: decodeURIComponent(
    String(Qt.resolvedUrl("ai_accounts.sh")).replace(/^file:\/\//, ""))
  readonly property string claudeSetupPath: decodeURIComponent(
    String(Qt.resolvedUrl("AddClaudeAccount.sh")).replace(/^file:\/\//, ""))
  readonly property string launchPath: decodeURIComponent(
    String(Qt.resolvedUrl("LaunchAccount.sh")).replace(/^file:\/\//, ""))
  readonly property string wrapperSetupPath: decodeURIComponent(
    String(Qt.resolvedUrl("InstallCommandWrappers.sh")).replace(/^file:\/\//, ""))

  property var accounts: []
  property string activeAccountId: ""
  property string activeName: "No saved account"
  property string suggestedName: ""
  property bool currentSaved: false
  property bool hasCurrentLogin: false
  property bool canSwitch: true
  property int runningCount: 0
  property bool busy: false
  property bool launching: false
  property bool commandWrappersEnabled: false
  property string switchingId: ""
  property string lastError: ""
  property bool hasActionError: false
  property string lastAction: ""
  property var usageByAccount: ({})
  property var usageQueue: []
  property int usageQueueIndex: 0
  property string usageAccountId: ""
  property double usageRefreshedAt: 0
  property bool usageRefreshRequested: false
  readonly property bool usageBusy: usageProcess.running
    || usageQueueIndex < usageQueue.length

  function boundedText(value, fallback, maximumLength) {
    var source = value === undefined || value === null || String(value) === ""
      ? String(fallback || "") : String(value)
    var limit = Math.max(1, Number(maximumLength || 256))
    source = source.trim()
    return source.length <= limit ? source : source.slice(0, limit - 1) + "…"
  }

  function displayAccount(value) {
    value = value || {}
    return {
      id: root.boundedText(value.id, "", 128),
      name: root.boundedText(value.name, "Account", 120),
      email: root.boundedText(value.email, "", 254),
      subscription_type: root.boundedText(value.subscription_type, "", 80),
      org_name: root.boundedText(value.org_name, "", 120),
      is_active: value.is_active === true,
      is_current: value.is_current === true,
      last_used_at: root.boundedText(value.last_used_at, "", 80)
    }
  }

  function displayUsage(value) {
    value = value || {}
    var receivedWindows = Array.isArray(value.windows) ? value.windows : []
    var windows = receivedWindows.slice(0, 4).map(function(window) {
      window = window || {}
      var percent = Number(window.used_percent)
      var reset = Number(window.resets_at)
      return {
        key: root.boundedText(window.key, "window", 40),
        label: root.boundedText(window.label, "limit", 20),
        used_percent: isFinite(percent) ? Math.max(0, Math.min(100, percent)) : 0,
        resets_at: isFinite(reset) && reset > 0 ? reset : 0
      }
    })
    return {
      loading: value.loading === true,
      available: value.available === true && windows.length > 0,
      windows: windows,
      reason: root.boundedText(value.reason, "Usage unavailable", 120),
      fetched_at: root.boundedText(value.fetched_at, "", 80)
    }
  }

  function usageFor(accountId) {
    return root.usageByAccount[String(accountId || "")]
      || root.displayUsage({ loading: root.usageBusy })
  }

  function parseResult(text) {
    try {
      var parsed = JSON.parse(String(text || "{}"))
      return parsed && typeof parsed === "object" ? parsed : {}
    } catch (error) {
      return { ok: false, error: "The account helper returned invalid data" }
    }
  }

  function applyStatus(payload) {
    payload = payload || {}
    root.commandWrappersEnabled = payload.command_wrappers_enabled === true
    var receivedAccounts = Array.isArray(payload.accounts) ? payload.accounts : []
    root.accounts = receivedAccounts.map(function(account) { return root.displayAccount(account) })
    root.activeAccountId = root.boundedText(payload.active_account_id, "", 128)
    root.currentSaved = payload.current_saved === true
    root.hasCurrentLogin = payload.has_current_login === true
    root.suggestedName = root.boundedText(payload.suggested_name, "", 120)
    root.canSwitch = payload.can_switch !== false
    var count = Number(payload.running_count || 0)
    root.runningCount = isFinite(count) ? Math.max(0, Math.floor(count)) : 0
    var active = null
    for (var i = 0; i < root.accounts.length; i++) {
      if (String(root.accounts[i].id || "") === root.activeAccountId) {
        active = root.accounts[i]
        break
      }
    }
    root.activeName = active ? root.boundedText(active.name, "Account", 120)
      : (root.hasCurrentLogin ? "Unsaved login" : "No Claude login")
    if (payload.ok === false && !root.hasActionError)
      root.lastError = root.boundedText(payload.error, "Could not load accounts", 320)
  }

  function refresh(forceUsage) {
    if (forceUsage !== false) root.usageRefreshRequested = true
    if (!statusProcess.running && !actionProcess.running) statusProcess.running = true
  }

  function refreshUsage(force) {
    var now = Date.now()
    if (root.usageBusy) {
      if (force === true) root.usageRefreshRequested = true
      return
    }
    if (force !== true && now - root.usageRefreshedAt < 300000) return

    var queue = []
    var nextUsage = Object.assign({}, root.usageByAccount)
    for (var i = 0; i < root.accounts.length; i++) {
      var accountId = root.boundedText(root.accounts[i].id, "", 128)
      if (accountId === "") continue
      queue.push(accountId)
      if (!nextUsage[accountId]) nextUsage[accountId] = root.displayUsage({ loading: true })
    }
    root.usageByAccount = nextUsage
    root.usageQueue = queue
    root.usageQueueIndex = 0
    root.usageRefreshedAt = now
    root.runNextUsage()
  }

  function runNextUsage() {
    if (usageProcess.running) return
    if (root.usageQueueIndex >= root.usageQueue.length) {
      root.usageQueue = []
      root.usageQueueIndex = 0
      if (root.usageRefreshRequested) {
        root.usageRefreshRequested = false
        root.refreshUsage(true)
      }
      return
    }
    root.usageAccountId = String(root.usageQueue[root.usageQueueIndex] || "")
    root.usageQueueIndex++
    usageProcess.command = ["bash", root.helperPath, "usage", root.usageAccountId]
    usageProcess.running = true
  }

  function runAction(arguments, switchingId) {
    if (root.busy) return
    root.busy = true
    root.switchingId = switchingId || ""
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    actionProcess.command = ["bash", root.helperPath].concat(arguments)
    actionProcess.running = true
  }

  function switchAccount(accountId) {
    if (String(accountId || "") === "") return
    runAction(["switch", String(accountId)], String(accountId))
  }

  function importCurrent(name) {
    runAction(["import-current", String(name || "")], "")
  }

  function renameAccount(accountId, name) {
    runAction(["rename", String(accountId), String(name || "")], "")
  }

  function removeAccount(accountId) {
    runAction(["remove", String(accountId)], "")
  }

  function addAnotherAccount() {
    if (setupProcess.running) return
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    setupProcess.command = ["omarchy-launch-terminal", "bash", root.claudeSetupPath]
    setupProcess.running = true
  }

  function launchSelectedAccount() {
    if (root.launching || root.activeAccountId === "") return
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    root.launching = true
    launchProcess.command = ["omarchy-launch-terminal", "bash", root.launchPath,
      root.activeAccountId]
    launchProcess.running = true
  }

  function enableCommandSwitching() {
    if (root.busy || wrapperProcess.running) return
    root.busy = true
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    wrapperProcess.command = ["bash", root.wrapperSetupPath, "install"]
    wrapperProcess.running = true
  }

  property Process statusProcess: Process {
    command: ["bash", root.helperPath, "status"]
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    stderr: StdioCollector { id: statusError; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseResult(statusOutput.text)
      if (exitCode === 0 && payload.ok === true) {
        root.applyStatus(payload)
        if (!root.hasActionError) root.lastError = ""
        var forceUsage = root.usageRefreshRequested
        root.usageRefreshRequested = false
        root.refreshUsage(forceUsage)
      } else {
        if (!root.hasActionError)
          root.lastError = root.boundedText(payload.error || statusError.text,
            "Could not load accounts", 320)
      }
    }
  }

  property Process usageProcess: Process {
    stdout: StdioCollector { id: usageOutput; waitForEnd: true }
    stderr: StdioCollector { id: usageError; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseResult(usageOutput.text)
      var key = root.usageAccountId
      var nextUsage = Object.assign({}, root.usageByAccount)
      if (exitCode === 0 && payload.ok === true) {
        nextUsage[key] = root.displayUsage(payload)
      } else {
        nextUsage[key] = root.displayUsage({
          available: false,
          reason: payload.error || usageError.text || "Usage unavailable"
        })
      }
      root.usageByAccount = nextUsage
      Qt.callLater(root.runNextUsage)
    }
  }

  property Process actionProcess: Process {
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    stderr: StdioCollector { id: actionError; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseResult(actionOutput.text)
      root.busy = false
      root.switchingId = ""
      if (exitCode === 0 && payload.ok === true) {
        root.lastAction = root.boundedText(payload.message, "Done", 240)
        root.lastError = ""
        root.hasActionError = false
      } else {
        root.lastError = root.boundedText(payload.error || actionError.text,
          "Account action failed", 320)
        root.hasActionError = true
      }
      root.refresh()
    }
  }

  property Process setupProcess: Process {
    onExited: refreshTimer.restart()
  }

  property Process launchProcess: Process {
    onExited: function(exitCode) {
      root.launching = false
      if (exitCode !== 0) {
        root.lastError = "Could not open the selected Claude account"
        root.hasActionError = true
      }
      refreshTimer.restart()
    }
  }

  property Process wrapperProcess: Process {
    stdout: StdioCollector { id: wrapperOutput; waitForEnd: true }
    stderr: StdioCollector { id: wrapperError; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseResult(wrapperOutput.text)
      root.busy = false
      if (exitCode === 0 && payload.ok === true) {
        root.lastAction = root.boundedText(payload.message, "Terminal commands enabled", 240)
        root.lastError = ""
        root.hasActionError = false
      } else {
        root.lastError = root.boundedText(payload.error || wrapperError.text,
          "Could not enable terminal command switching", 320)
        root.hasActionError = true
      }
      root.refresh()
    }
  }

  FileView {
    path: root.claudeStorePath
    watchChanges: true
    printErrors: false
    onLoaded: root.refresh()
    onFileChanged: reload()
    onLoadFailed: root.refresh()
  }

  Timer {
    id: refreshTimer
    interval: 700
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  Component.onCompleted: root.refresh(false)
}
