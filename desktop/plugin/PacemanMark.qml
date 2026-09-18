import QtQuick

// Optical adaptation of iOS CompanionBrandMark: one identity on both surfaces.
Item {
  id: root
  property color ink: "white"
  implicitWidth: 24
  implicitHeight: 24
  readonly property real unit: Math.min(width, height) / 24
  Item {
    width: 24 * root.unit
    height: 24 * root.unit
    anchors.centerIn: parent
    Rectangle {
      x: 3.3 * root.unit; y: 6.3 * root.unit
      width: 17.4 * root.unit; height: 14 * root.unit
      radius: 4.6 * root.unit
      color: "transparent"
      border.color: root.ink
      border.width: Math.max(1, 1.25 * root.unit)
      antialiasing: true
    }
    Rectangle {
      x: 11.35 * root.unit; y: 3.4 * root.unit
      width: 1.3 * root.unit; height: 3.5 * root.unit
      radius: width / 2; color: root.ink
    }
    Rectangle {
      x: 10.65 * root.unit; y: 1.3 * root.unit
      width: 2.7 * root.unit; height: width
      radius: width / 2; color: root.ink
      antialiasing: true
    }
    Repeater {
      model: [8.3, 14.2]
      Rectangle {
        required property real modelData
        x: modelData * root.unit; y: 11.3 * root.unit
        width: 1.6 * root.unit; height: 3.7 * root.unit
        radius: width / 2; color: root.ink
        antialiasing: true
      }
    }
    Repeater {
      model: [0.5, 22.1]
      Rectangle {
        required property real modelData
        x: modelData * root.unit; y: 11.1 * root.unit
        width: 1.4 * root.unit; height: 4.2 * root.unit
        radius: width / 2; color: root.ink
        antialiasing: true
      }
    }
  }
}
