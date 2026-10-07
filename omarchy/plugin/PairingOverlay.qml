import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Match Omarchy's Wi-Fi QR: centered content over a workspace-sized scrim.
PanelWindow {
  id: root
  property var pairing: ({})
  property double now: Date.now() / 1000
  property bool busy: false
  property string error: ""
  property bool canPair: true
  property string fontFamily: Style.font.family
  readonly property bool codeValid: String(pairing.qrPath || "") !== "" && Number(pairing.expiresAt || 0) > now
  signal dismissed()
  signal regenerateRequested()
  visible: false
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "paceman-pairing"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  onVisibleChanged: if (visible) keys.forceActiveFocus()

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.78)
    MouseArea { anchors.fill: parent; onClicked: root.dismissed() }
  }
  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: root.dismissed()
    Keys.onReturnPressed: if (!root.codeValid && !root.busy && root.canPair) root.regenerateRequested()
    Keys.onSpacePressed: if (!root.codeValid && !root.busy && root.canPair) root.regenerateRequested()
    Item {
      anchors.centerIn: parent
      width: Style.space(360)
      height: content.implicitHeight
      scale: Math.min(1, (keys.width - Style.space(32)) / width,
        (keys.height - Style.space(32)) / Math.max(1, height))
      MouseArea { anchors.fill: parent; onClicked: {} }
      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(16)
        PacemanMark {
          Layout.alignment: Qt.AlignHCenter
          implicitWidth: Style.font.display
          implicitHeight: Style.font.display
          ink: "white"
        }
        Text {
          Layout.fillWidth: true
          text: "PACEMAN"
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
          horizontalAlignment: Text.AlignHCenter
        }
        Image {
          visible: root.codeValid && !root.busy
          Layout.alignment: Qt.AlignHCenter
          Layout.preferredWidth: Style.space(240)
          Layout.preferredHeight: Style.space(240)
          source: root.codeValid ? "file://" + encodeURI(String(root.pairing.qrPath)) + "#" + String(root.pairing.expiresAt) : ""
          cache: false
          smooth: false
          fillMode: Image.PreserveAspectFit
        }
        Text {
          Layout.fillWidth: true
          text: root.busy ? "Creating pairing code…" : root.error !== "" ? root.error
            : root.codeValid ? "On your iPhone, open Paceman → Connect computer → Scan QR code to connect."
            : "This code has expired. Generate a new one to connect your phone."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          color: "#dddddd"
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          visible: root.codeValid && !root.busy
          Layout.fillWidth: true
          text: "Expires in " + Math.ceil((Number(root.pairing.expiresAt) - root.now) / 60) + " min"
          horizontalAlignment: Text.AlignHCenter
          color: "#aaaaaa"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Button {
          visible: !root.codeValid && !root.busy
          Layout.alignment: Qt.AlignHCenter
          text: "NEW PAIRING CODE"
          enabled: root.canPair
          foreground: "white"
          fontFamily: root.fontFamily
          hasCursor: true
          onClicked: root.regenerateRequested()
        }
        Text {
          Layout.fillWidth: true
          text: "Esc or click outside to close"
          horizontalAlignment: Text.AlignHCenter
          color: "#aaaaaa"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
