import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "PanelModel.js" as Model

PanelKeyCatcher {
  id: root
  property var sourceState: ({})
  property double now: Date.now() / 1000
  property bool busy: false
  property string actionError: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool phoneExpanded: false
  property string expandedClient: ""
  property string removalClient: ""
  property bool animateActivity: true
  property string cursor: ""
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var view: Model.present(sourceState, now)
  onCursorChanged: {
    if (cursor === "pair" || cursor === "sharing") revealRequested(hero)
    else if (cursor === "restart") revealRequested(restartButton)
    else if (cursor.indexOf("agent:") === 0) revealRequested(agentSection)
    else if (cursor === "help") revealRequested(setupGuideButton)
  }
  implicitHeight: content.implicitHeight
  signal agentRequested(string provider, bool enabled)
  signal sharingRequested(bool enabled)
  signal removeRequested(string clientId)
  signal restartRequested()
  signal pairRequested()
  signal dismissRequested()
  signal panelSwitchRequested(int direction)
  signal revealRequested(var item)

  function back() {
    if (removalClient) { cursor = "remove:" + removalClient; removalClient = "" }
    else if (phoneExpanded || expandedClient) { phoneExpanded = false; expandedClient = "" }
    else dismissRequested()
  }
  function targets() {
    var items = busy ? [] : (view.running && view.sharing ? ["pair", "sharing"] : ["sharing"])
    if (view.connections.length === 0 && !busy) items.push("help")
    view.connections.forEach(function(client, index) {
      items.push("phone:" + client.id)
      if ((expandedClient === client.id || (phoneExpanded && index === 0)) && client.canRemove && !busy) {
        if (removalClient === client.id) items.push("cancel:" + client.id, "confirm:" + client.id)
        else items.push("remove:" + client.id)
      }
    })
    if ((view.sharing && !view.running) && !busy) items.push("restart")
    if (!busy) view.agents.forEach(function(agent) { items.push("agent:" + agent.id) })
    return items
  }
  function activate(target) {
    var parts = target.split(":"), action = parts[0], id = parts.slice(1).join(":")
    if (action === "phone") {
      var wasExpanded = expandedClient === id || (phoneExpanded && view.connections[0].id === id)
      phoneExpanded = false
      expandedClient = wasExpanded ? "" : id
      removalClient = ""
    } else if (!busy) {
      if (action === "agent") {
        var agent = view.agents.filter(function(value) { return value.id === id })[0]
        if (agent) agentRequested(id, !agent.enabled)
      }
      else if (action === "sharing") sharingRequested(!view.sharing)
      else if (action === "pair") pairRequested()
      else if (action === "restart") restartRequested()
      else if (action === "help") Qt.openUrlExternally("https://github.com/iamjamesim/paceman#get-started")
      else if (action === "remove") { removalClient = id; cursor = "cancel:" + id }
      else if (action === "cancel") { removalClient = ""; cursor = "remove:" + id }
      else if (action === "confirm" && removalClient === id) removeRequested(id)
    }
  }
  onMoveRequested: function(dx, dy) {
    var items = targets()
    var index = items.indexOf(cursor)
    var delta = dy || dx
    cursor = items[index < 0 ? 0 : (index + (delta > 0 ? 1 : -1) + items.length) % items.length]
  }
  onActivateRequested: activate(cursor)
  onCloseRequested: back()
  onTabRequested: function(direction) { panelSwitchRequested(direction) }

  ColumnLayout {
    id: content
    width: parent.width
    spacing: Style.space(14)

    PanelHero {
      id: hero
      Layout.fillWidth: true
      title: "Paceman"
      meta: root.view.subtitle
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconOpacity: root.view.sharing && root.view.running ? 1 : 0.5
      iconComponent: Component {
        PacemanMark {
          implicitWidth: Style.font.display
          implicitHeight: Style.font.display
          ink: root.foreground
        }
      }
      trailingControl: Component {
        RowLayout {
          spacing: Style.space(8)
          Button {
            iconText: "󰐲"
            tooltipText: "Connect a phone"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSize: Style.font.subtitle * 1.5
            horizontalPadding: Style.space(5)
            verticalPadding: Style.space(2)
            enabled: root.view.running && root.view.sharing && !root.busy
            hasCursor: root.cursor === "pair"
            onHovered: function(on) { if (on) root.cursor = "pair" }
            onClicked: root.activate("pair")
            Accessible.name: "Connect a phone"
          }
          ToggleSwitch {
            id: sharingSwitch
            checked: root.view.sharing
            busy: root.busy
            interactive: !root.busy
            foreground: root.foreground
            hasCursor: root.cursor === "sharing"
            onHovered: function(on) { if (on) root.cursor = "sharing" }
            onToggled: root.activate("sharing")
            Accessible.name: "Share activity from this computer"
            Accessible.role: Accessible.CheckBox
            Accessible.checked: checked
            PanelToolTip {
              visible: sharingSwitch.containsMouse
              text: root.view.sharing ? "Turn sharing off" : "Turn sharing on"
              fontFamily: root.fontFamily
            }
          }
        }
      }
    }
    PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(10)
      PanelSectionHeader {
        text: root.view.connectionHeading
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
      Repeater {
        model: root.view.connections
        delegate: ConnectionRow {
          required property var modelData
          Layout.fillWidth: true
          connection: modelData
          expanded: root.expandedClient === modelData.id || (root.phoneExpanded && root.view.connections[0].id === modelData.id)
          confirming: root.removalClient === modelData.id
          busy: root.busy
          cursor: root.cursor
          foreground: root.foreground
          fontFamily: root.fontFamily
          now: root.now
          onActivateRequested: function(target) { root.activate(target) }
          onCursorRequested: function(target) { root.cursor = target }
          onRevealRequested: function(item) { root.revealRequested(item) }
        }
      }
      ColumnLayout {
        visible: root.view.connections.length === 0
        Layout.fillWidth: true
        spacing: Style.space(8)
        Text {
          text: "Connect your phone"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
        Text {
          Layout.fillWidth: true
          text: root.view.guidance
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Button {
          id: setupGuideButton
          Layout.fillWidth: true
          text: "SETUP GUIDE"
          bordered: true
          enabled: !root.busy
          foreground: root.foreground
          fontFamily: root.fontFamily
          hasCursor: root.cursor === "help"
          onHovered: function(on) { if (on) root.cursor = "help" }
          onClicked: root.activate("help")
          Accessible.name: "Setup guide"
        }
      }
      Button {
        id: restartButton
        visible: root.view.sharing && !root.view.running
        Layout.fillWidth: true
        text: root.busy ? "STARTING…" : "RESTART PACEMAN"
        bordered: true
        enabled: !root.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        hasCursor: root.cursor === "restart"
        onHovered: function(on) { if (on) root.cursor = "restart" }
        onClicked: root.activate("restart")
      }
      PanelSeparator { Layout.fillWidth: true; Layout.topMargin: Style.space(4); foreground: root.foreground }
      PanelSectionHeader {
        Layout.topMargin: Style.space(4)
        text: "ACTIVITY"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
      ColumnLayout {
        id: agentSection
        Layout.fillWidth: true
        spacing: Style.space(10)
        Repeater {
          model: root.view.agents.length ? root.view.agents : [{id: "codex", title: root.view.activityTitle,
            label: root.view.activity, activity: root.sourceState.activity || "idle", enabled: true,
            detail: root.view.activityBreakdown, guidance: root.view.activityGuidance}]
          delegate: ColumnLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(4)
            RowLayout {
              Layout.fillWidth: true
              Layout.bottomMargin: Style.space(2)
              spacing: Style.space(10)
              Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: modelData.title
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }
              Text {
                Layout.maximumWidth: root.width * .48
                text: modelData.label
                horizontalAlignment: Text.AlignRight
                wrapMode: Text.WordWrap
                color: modelData.activity === "needs_input" && root.view.running && root.view.sharing ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Item {
                // Reserve the same trailing slot even when there is no activity mark.
                Layout.minimumWidth: Style.space(24)
                Layout.maximumWidth: Style.space(24)
                implicitHeight: Style.space(24)
                PacemanMark {
                  id: activityMark
                  anchors.centerIn: parent
                  width: parent.width
                  height: parent.height
                  visible: root.view.running && root.view.sharing
                    && ["working", "needs_input", "failed", "finished"].indexOf(modelData.activity) >= 0
                  expression: modelData.activity
                  ink: root.foreground
                  property real bounceOffset: 0
                  property real swayPhase: 0
                  transform: [
                    Translate {
                      x: modelData.activity === "finished"
                        ? Math.sin(activityMark.swayPhase * Math.PI / 180) * 2 : 0
                      y: activityMark.bounceOffset
                    },
                    Rotation {
                      origin.x: activityMark.width / 2
                      origin.y: activityMark.height / 2
                      angle: modelData.activity === "finished"
                        ? Math.sin(activityMark.swayPhase * Math.PI / 180) * 4 : 0
                    }
                  ]
                  Accessible.ignored: true
                  SequentialAnimation on opacity {
                    running: root.animateActivity && activityMark.visible && modelData.activity === "working"
                    loops: Animation.Infinite
                    alwaysRunToEnd: false
                    onStopped: activityMark.opacity = 1
                    NumberAnimation { from: 1; to: 0.4; duration: 1300; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.4; to: 1; duration: 1300; easing.type: Easing.InOutSine }
                  }
                  SequentialAnimation on bounceOffset {
                    running: root.animateActivity && activityMark.visible && modelData.activity === "needs_input"
                    loops: Animation.Infinite
                    alwaysRunToEnd: false
                    onStopped: activityMark.bounceOffset = 0
                    NumberAnimation { from: 0; to: -3; duration: 320; easing.type: Easing.InOutSine }
                    NumberAnimation { from: -3; to: 0; duration: 320; easing.type: Easing.InOutSine }
                    PauseAnimation { duration: 360 }
                  }
                  NumberAnimation on swayPhase {
                    running: root.animateActivity && activityMark.visible && modelData.activity === "finished"
                    loops: Animation.Infinite
                    alwaysRunToEnd: false
                    from: 0; to: 360; duration: 4200
                    onStopped: activityMark.swayPhase = 0
                  }
                }
              }
              ToggleSwitch {
                visible: root.view.agents.length > 0
                checked: modelData.enabled
                busy: root.busy
                interactive: !root.busy
                foreground: root.foreground
                hasCursor: root.cursor === "agent:" + modelData.id
                onHovered: function(on) { if (on) root.cursor = "agent:" + modelData.id }
                onToggled: root.activate("agent:" + modelData.id)
                Accessible.name: "Monitor " + modelData.title
                Accessible.role: Accessible.CheckBox
                Accessible.checked: checked
              }
            }
            Text {
              Layout.fillWidth: true
              visible: text !== ""
              text: modelData.detail
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              Layout.fillWidth: true
              visible: text !== ""
              text: root.view.agentGuidance ? "" : modelData.guidance
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: root.view.agentGuidance
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: text !== ""
      text: root.actionError
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
