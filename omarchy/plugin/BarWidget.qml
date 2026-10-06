import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PanelModel.js" as Model

Panel {
  id: root
  moduleName: "io.github.iamjamesim.paceman"
  ipcTarget: "paceman"
  property var sourceState: ({})
  property var configuredProviders: null
  property bool sharingEnabled: true
  property double now: Date.now() / 1000
  property string actionError: ""
  property string action: ""
  property var pairing: ({})
  property bool pairingOpen: false
  readonly property var displayState: Object.assign({}, sourceState, {sharingEnabled: sharingEnabled,
    configuredProviders: configuredProviders === null ? sourceState.configuredProviders : configuredProviders})
  readonly property var view: Model.present(displayState, now)
  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property string ctlPath: Quickshell.env("HOME") + "/.local/bin/pacemanctl"
  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() { stateFile.reload(); pauseFile.reload(); agentsFile.reload(); if (!statusQuery.running) statusQuery.running = true }
  function showPairing() {
    if (command.running || !view.running || !view.sharing) return
    pairing = ({})
    pairingOpen = true
    close()
    run(["pair", "--json"])
  }
  function run(args) {
    if (command.running) return
    actionError = ""
    action = args[0] === "agents" && args[1] === "--repair" ? "repair-hooks" : args[0]
    command.command = [ctlPath].concat(args)
    command.running = true
  }
  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) {
    now = Date.now() / 1000
    refresh()
    pairingOpen = false
    pairing = ({})
    content.phoneExpanded = false
    content.expandedClient = ""
    content.removalClient = ""
    content.cursor = ""
    scroll.contentY = 0
    actionError = ""
  }
  Timer {
    interval: root.pairingOpen ? 1000 : 5000
    running: true
    repeat: true
    onTriggered: {
      root.now = Date.now() / 1000
      stateFile.reload()
      pauseFile.reload()
      if (root.opened && !statusQuery.running) statusQuery.running = true
    }
  }
  FileView {
    id: stateFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/paceman/status.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.now = Date.now() / 1000
        if (Number(parsed.schema) === 1) root.sourceState = Object.assign({}, root.sourceState, parsed)
      } catch (error) { root.sourceState = ({}) }
    }
  }
  FileView {
    id: pauseFile
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/paceman/sharing-paused"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.sharingEnabled = false
    onLoadFailed: root.sharingEnabled = true
  }
  FileView {
    id: agentsFile
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/paceman/agents.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var providers = JSON.parse(text()).providers
        if (Array.isArray(providers) && providers.every(function(p) { return p === "codex" || p === "claude" }))
          root.configuredProviders = providers
      } catch (error) { console.warn("Paceman agent settings unavailable") }
    }
  }
  Process {
    id: statusQuery
    command: [root.ctlPath, "status"]
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) {
        try {
          var value = JSON.parse(statusOutput.text)
          root.now = Date.now() / 1000
          root.sourceState = value
          root.sharingEnabled = value.sharingEnabled !== false
        } catch (error) { console.warn("Paceman status unavailable") }
      }
    }
  }
  Process {
    id: command
    stderr: StdioCollector { id: errors; waitForEnd: true }
    stdout: StdioCollector { id: output; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        var detail = String(errors.text || "").trim()
        root.actionError = root.action === "pair"
          ? (detail.indexOf("Paceman route: ") === 0
              ? detail.slice("Paceman route: ".length)
              : "Couldn't create a pairing code. Run pacemanctl pair for details.")
          : root.action === "remove-access" ? "Couldn't remove access. Try again or check pacemanctl logs."
          : root.action === "repair-hooks" ? "Couldn’t restore hooks. Check the agent’s settings, then try again."
          : root.action === "agents" ? "Couldn't change agent monitoring. Run pacemanctl agents for details."
          : "Couldn't change sharing. Try again or check pacemanctl logs."
        console.warn("Paceman action failed:", detail || "Unknown error")
      } else if (root.action === "pair") {
        try { if (root.pairingOpen) root.pairing = JSON.parse(output.text) }
        catch (error) { root.actionError = "Couldn't read the pairing code. Try again." }
      } else if (root.action === "share-off") {
        root.pairing = ({})
        root.pairingOpen = false
      } else if (root.action === "agents" || root.action === "repair-hooks") {
        try { root.sourceState = JSON.parse(output.text); root.configuredProviders = root.sourceState.configuredProviders }
        catch (error) { root.refresh() }
      } else if (root.action === "remove-access") {
        try { root.sourceState = JSON.parse(output.text) } catch (error) { root.refresh() }
        content.removalClient = ""
        content.expandedClient = ""
        content.phoneExpanded = false
        content.cursor = ""
      }
      root.refresh()
    }
  }
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Paceman · " + root.view.subtitle.toLowerCase()
    iconComponent: Component {
      PacemanMark {
        ink: root.foreground
        opacity: root.view.running && root.view.sharing ? 1 : 0.5
      }
    }
    onPressed: root.toggle()
  }
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: content
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)
    Flickable {
      id: scroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      function reveal(item) {
        var y = item.mapToItem(content, 0, 0).y
        if (y < contentY) contentY = y
        else if (y + item.height > contentY + height) contentY = y + item.height - height
        contentY = Math.max(0, Math.min(contentY, contentHeight - height))
      }
      PanelContent {
        id: content
        width: parent.width
        sourceState: root.displayState
        now: root.now
        busy: command.running
        animateActivity: root.opened
        actionError: root.actionError
        foreground: root.foreground
        fontFamily: root.fontFamily
        onAgentRequested: function(provider, enabled) { root.run(["agents", enabled ? "--enable" : "--disable", provider]) }
        onHookRepairRequested: function(provider) { root.run(["agents", "--repair", provider]) }
        onSharingRequested: function(enabled) { root.run([enabled ? "share-on" : "share-off"]) }
        onRestartRequested: root.run(["restart"])
        onPairRequested: root.showPairing()
        onRemoveRequested: function(clientId) { root.run(["remove-access", "--client-id", clientId]) }
        onDismissRequested: root.close()
        onPanelSwitchRequested: function(direction) { root.switchPanel(direction) }
        onRevealRequested: function(item) { scroll.reveal(item) }
      }
    }
  }
  PairingOverlay {
    visible: root.pairingOpen
    pairing: root.pairing
    now: root.now
    busy: command.running
    error: root.actionError
    canPair: root.view.running && root.view.sharing
    fontFamily: root.fontFamily
    onDismissed: {
      root.pairingOpen = false
      root.pairing = ({})
      root.actionError = ""
    }
    onRegenerateRequested: root.showPairing()
  }
}
