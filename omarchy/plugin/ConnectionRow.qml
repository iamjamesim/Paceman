import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "PanelModel.js" as Model

ColumnLayout {
  id: root
  required property var connection
  property bool expanded: false
  property bool confirming: false
  property bool busy: false
  property string cursor: ""
  property double now: Date.now() / 1000
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)
  signal activateRequested(string target)
  signal cursorRequested(string target)
  signal revealRequested(var item)
  onCursorChanged: {
    var items = {phone: connectionSurface, remove: removeButton, cancel: cancelButton, confirm: confirmButton}
    if (cursor.endsWith(":" + connection.id) && items[cursor.split(":")[0]]) {
      var item = items[cursor.split(":")[0]]
      Qt.callLater(function() { root.revealRequested(item) })
    }
  }
  spacing: Style.space(10)

  CursorSurface {
    id: connectionSurface
    Layout.fillWidth: true
    implicitHeight: row.implicitHeight + Style.space(16)
    foreground: root.foreground
    hasCursor: root.cursor === "phone:" + root.connection.id
    Accessible.name: root.connection.title + ". " + root.connection.status
      + (root.connection.lastContactAt > 0 ? ", " + Model.relativeTime(root.connection.lastContactAt, root.now) : "")
    Accessible.role: Accessible.Button
    Accessible.description: root.expanded ? "Collapse connection details" : "Expand connection details"
    RowLayout {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(10)
      spacing: Style.space(14)
      Text {
        text: root.connection.phone ? "󰄜" : "󰌷"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        Text {
          Layout.fillWidth: true
          text: root.connection.title
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
        Text {
          Layout.fillWidth: true
          text: root.connection.status
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
      Text {
        visible: root.connection.lastContactAt > 0
        text: Model.relativeTime(root.connection.lastContactAt, root.now)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        text: root.expanded ? "󰅀" : "󰅂"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorRequested("phone:" + root.connection.id)
      onClicked: root.activateRequested("phone:" + root.connection.id)
    }
  }
  ColumnLayout {
    visible: root.expanded
    Layout.fillWidth: true
    Layout.leftMargin: Style.space(10)
    Layout.rightMargin: Style.space(10)
    spacing: Style.space(12)
    Text {
      Layout.fillWidth: true
      visible: root.connection.pairedAt > 0
      text: "Paired " + Qt.formatDateTime(new Date(root.connection.pairedAt * 1000), "MMM d, yyyy · h:mm AP")
      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
    Text {
      Layout.fillWidth: true
      visible: !root.connection.recent
      text: root.connection.guidance
      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
    Button {
      id: removeButton
      visible: root.connection.canRemove && !root.confirming
      text: "Remove access…"
      enabled: !root.busy
      foreground: root.foreground; fontFamily: root.fontFamily
      hasCursor: root.cursor === "remove:" + root.connection.id
      onHovered: function(on) { if (on) root.cursorRequested("remove:" + root.connection.id) }
      onClicked: root.activateRequested("remove:" + root.connection.id)
    }
    ColumnLayout {
      visible: root.confirming
      Layout.fillWidth: true
      spacing: Style.space(10)
      Text {
        Layout.fillWidth: true
        text: "Remove access for “" + root.connection.title + "”? Updates from this computer will stop. "
          + (root.connection.platform === "ios" ? "Your watch stays paired. " : "")
          + "A new code is needed to reconnect."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)
        Button {
          id: cancelButton
          Layout.fillWidth: true
          text: "Cancel"; bordered: true; enabled: !root.busy
          foreground: root.foreground; fontFamily: root.fontFamily
          hasCursor: root.cursor === "cancel:" + root.connection.id
          onHovered: function(on) { if (on) root.cursorRequested("cancel:" + root.connection.id) }
          onClicked: root.activateRequested("cancel:" + root.connection.id)
        }
        Button {
          id: confirmButton
          Layout.fillWidth: true
          text: root.busy ? "Removing…" : "Remove access"; bordered: true; enabled: !root.busy
          foreground: root.foreground; fontFamily: root.fontFamily
          hasCursor: root.cursor === "confirm:" + root.connection.id
          onHovered: function(on) { if (on) root.cursorRequested("confirm:" + root.connection.id) }
          onClicked: root.activateRequested("confirm:" + root.connection.id)
        }
      }
    }
  }
}
