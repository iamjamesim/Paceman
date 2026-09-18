import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "plugin" as Paceman

PanelWindow {
  id: window
  anchors.top: true
  margins.top: 32
  exclusionMode: ExclusionMode.Ignore
  implicitWidth: 864
  implicitHeight: 680
  visible: true
  color: Color.background
  readonly property double now: Date.now() / 1000
  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 16
    spacing: 12
    Text {
      text: "PACEMAN / DESKTOP PANEL — SAMPLE STATES"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Color.foreground
    }
    GridLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      columns: 2
      uniformCellWidths: true
      columnSpacing: 16
      rowSpacing: 16
      Repeater {
        model: Quickshell.env("PACEMAN_PREVIEW_SESSIONS") === "1" ? [
          {label: "One session", running: true, sharingEnabled: true, pairedPhones: 1, lastPhoneFetchAt: window.now - 3,
            activity: "working", sessions: 1, sessionCounts: {needs_input: 0, working: 1, finished: 0}},
          {label: "Two working", running: true, sharingEnabled: true, pairedPhones: 1, lastPhoneFetchAt: window.now - 3,
            activity: "working", sessions: 2, sessionCounts: {needs_input: 0, working: 2, finished: 0}},
          {label: "Mixed states", running: true, sharingEnabled: true, pairedPhones: 1, lastPhoneFetchAt: window.now - 3,
            activity: "needs_input", sessions: 2, sessionCounts: {needs_input: 1, working: 1, finished: 0}},
          {label: "Active work plus retained completion", running: true, sharingEnabled: true, pairedPhones: 1, lastPhoneFetchAt: window.now - 3,
            activity: "needs_input", sessions: 6, sessionCounts: {needs_input: 2, working: 3, finished: 1}}
        ] : [
          {label: "Receiving updates", running: true, sharingEnabled: true, pairedPhones: 1, lastPhoneFetchAt: window.now - 3, activity: "working"},
          {label: "Phone away", running: true, sharingEnabled: true, pairedPhones: 1, lastPhoneFetchAt: window.now - 900, activity: "needs_input"},
          {label: "First-time setup", running: true, sharingEnabled: true, pairedPhones: 0, lastPhoneFetchAt: 0, activity: "idle"},
          {label: "Sharing off", running: false, sharingEnabled: false, pairedPhones: 1, lastPhoneFetchAt: window.now - 300, activity: "idle"}
        ]
        delegate: ColumnLayout {
          required property var modelData
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.minimumWidth: 0
          Layout.preferredWidth: (window.width - 48) / 2
          Layout.maximumWidth: (window.width - 48) / 2
          spacing: 8
          Text {
            text: modelData.label
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          BorderSurface {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            implicitHeight: panel.implicitHeight + Style.space(28)
            color: Color.popups.background
            borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
            Paceman.PanelContent {
              id: panel
              x: Style.space(14)
              y: Style.space(14)
              width: parent.width - Style.space(28)
              now: window.now
              sourceState: Object.assign({computerName: "Omarchy", updatedAt: window.now, schema: 1}, modelData)
            }
          }
          Item { Layout.fillHeight: true }
        }
      }
    }
  }
}
