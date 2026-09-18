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
  property bool animateActivity: true
  property string cursor: ""
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var view: Model.present(sourceState, now)
  implicitHeight: content.implicitHeight
  signal sharingRequested(bool enabled)
  signal restartRequested()
  signal pairRequested()
  signal dismissRequested()
  signal panelSwitchRequested(int direction)

  function back() {
    if (phoneExpanded) { phoneExpanded = false; cursor = "phone" }
    else dismissRequested()
  }
  function targets() {
    var items = busy ? [] : (view.running && view.sharing ? ["pair", "sharing"] : ["sharing"])
    items.push("phone")
    if ((view.sharing && !view.running) && !busy) items.push("restart")
    return items
  }
  function activate(target) {
    if (target === "phone") phoneExpanded = !phoneExpanded
    else if (!busy) {
      if (target === "sharing") sharingRequested(!view.sharing)
      else if (target === "pair") pairRequested()
      else if (target === "restart") restartRequested()
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
        text: "PHONE"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
      CursorSurface {
        Layout.fillWidth: true
        implicitHeight: phoneRow.implicitHeight + Style.space(16)
        foreground: root.foreground
        hasCursor: root.cursor === "phone"
        Accessible.name: root.view.phoneTitle + ". " + root.view.phoneStatus
        Accessible.role: Accessible.Button
        Accessible.description: root.phoneExpanded ? "Collapse connection details" : "Expand connection details"
        RowLayout {
          id: phoneRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(10)
          spacing: Style.space(14)
          Text {
            text: "󰄜"
            color: root.view.recent ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(3)
            Text {
              Layout.fillWidth: true
              text: root.view.phoneTitle
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }
            Text {
              Layout.fillWidth: true
              text: root.view.phoneStatus
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
          Text {
            visible: root.view.paired && root.view.running && root.view.sharing && Number(root.sourceState.lastPhoneFetchAt || 0) > 0
            text: Model.relativeTime(root.sourceState.lastPhoneFetchAt, root.now)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            text: root.phoneExpanded ? "󰅀" : "󰅂"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) root.cursor = "phone"
          onClicked: root.activate("phone")
        }
      }
      ColumnLayout {
        visible: root.phoneExpanded
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(10)
        Layout.rightMargin: Style.space(10)
        spacing: Style.space(12)
        RowLayout {
          Layout.fillWidth: true
          Text {
            text: "Last contact"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Item { Layout.fillWidth: true }
          Text {
            text: Number(root.sourceState.lastPhoneFetchAt || 0) > 0
              ? Model.relativeTime(root.sourceState.lastPhoneFetchAt, root.now) : "None since restart"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
        Text {
          Layout.fillWidth: true
          text: root.view.paired ? "Your pairing is saved." : "Pair this computer with Paceman on your iPhone."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
        Text {
          Layout.fillWidth: true
          visible: !root.view.recent
          text: root.view.sharing && root.view.running && root.view.paired
            ? "To resume updates, check that Tailscale is connected on both devices, then open Paceman on your iPhone."
            : root.view.guidance
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
      }
      Text {
        Layout.fillWidth: true
        visible: !root.view.recent && !root.phoneExpanded
        text: root.view.guidance
        wrapMode: Text.WordWrap
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Button {
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
      RowLayout {
        Layout.fillWidth: true
        Layout.bottomMargin: Style.space(2)
        spacing: Style.space(10)
        Text {
          text: root.view.activityTitle
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
        Text {
          Layout.fillWidth: true
          text: root.view.activity
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideRight
          color: root.sourceState.activity === "needs_input" && root.view.running && root.view.sharing ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Item {
          // Reserve the same trailing slot even when there is no activity mark.
          Layout.minimumWidth: Style.space(24)
          Layout.maximumWidth: Style.space(24)
          implicitHeight: Style.space(24)
          Text {
            id: activityMark
            anchors.centerIn: parent
            visible: root.view.running && root.view.sharing
              && ["working", "needs_input", "finished"].indexOf(root.sourceState.activity) >= 0
            text: root.sourceState.activity === "finished" ? "󱜙" : "󱚣"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle * 1.25
            Accessible.ignored: true
            SequentialAnimation on opacity {
              running: root.animateActivity && activityMark.visible && root.sourceState.activity === "working"
              loops: Animation.Infinite
              alwaysRunToEnd: false
              onStopped: activityMark.opacity = 1
              NumberAnimation { from: 1; to: 0.4; duration: 1300; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.4; to: 1; duration: 1300; easing.type: Easing.InOutSine }
            }
          }
        }
      }
      Text {
        Layout.fillWidth: true
        visible: text !== ""
        text: root.view.activityBreakdown
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
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
