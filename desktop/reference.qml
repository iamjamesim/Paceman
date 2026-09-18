import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "plugin" as Paceman

// Documentation captures use the production components with inert fixtures.
// No source socket, client credentials, or desktop command handlers are loaded.
Scope {
  id: root
  readonly property string scenario: Quickshell.env("PACEMAN_REFERENCE_STATE")
  readonly property string output: Quickshell.env("PACEMAN_REFERENCE_DIR") + "/" + scenario + ".png"
  readonly property double now: 1800000000
  readonly property var fixture: Object.assign({
    schema: 1, running: true, sharingEnabled: true, updatedAt: now,
    pairedPhones: 1, lastPhoneFetchAt: now - 3,
    activity: "working", sessions: 1,
    sessionCounts: {needs_input: 0, working: 1, finished: 0}
  }, scenario === "phone-details" ? {lastPhoneFetchAt: now - 900}
    : scenario === "multiple-sessions" ? {
      activity: "needs_input", sessions: 2,
      sessionCounts: {needs_input: 1, working: 1, finished: 0}
    } : scenario === "sharing-off" ? {running: false, sharingEnabled: false} : {})

  PanelWindow {
    visible: root.scenario !== "pairing"
    implicitWidth: stage.width
    implicitHeight: stage.height
    anchors.top: true
    margins.top: 60
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "paceman-reference"
    color: Color.background
    Rectangle {
      id: stage
      width: card.width + 32
      height: card.height + 32
      color: Color.background
      BorderSurface {
        id: card
        x: 16
        y: 16
        width: Style.space(380)
        height: panel.implicitHeight + contentTopInset + contentBottomInset
        padding: Style.spacing.popupPadding
        color: Color.popups.background
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius
        Paceman.PanelContent {
          id: panel
          x: card.contentLeftInset
          y: card.contentTopInset
          width: card.width - card.contentLeftInset - card.contentRightInset
          sourceState: root.fixture
          now: root.now
          phoneExpanded: root.scenario === "phone-details"
          animateActivity: false
        }
      }
    }
  }

  Paceman.PairingOverlay {
    id: pairing
    visible: root.scenario === "pairing"
    now: root.now
    pairing: ({qrPath: Quickshell.env("PACEMAN_REFERENCE_QR"), expiresAt: root.now + 300})
    // A plain documentation backdrop replaces the user's real workspace.
    Rectangle { anchors.fill: parent; z: -1; color: Color.background }
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: {
      if (root.scenario === "pairing") { overlayCapture.running = true; return }
      stage.grabToImage(function(result) {
        if (!result.saveToFile(root.output)) console.error("Could not save reference:", root.output)
        else console.info("Saved reference:", root.output)
        Qt.quit()
      })
    }
  }
  // Quickshell's window content item cannot use Qt's item-grab API. Capture
  // the overlay's output; its opaque fixture backdrop covers the real desktop.
  Process {
    id: overlayCapture
    command: ["grim", "-o", pairing.screen ? pairing.screen.name : "", root.output]
    onExited: function(code) {
      if (code !== 0) console.error("Could not capture pairing overlay")
      Qt.quit()
    }
  }
}
