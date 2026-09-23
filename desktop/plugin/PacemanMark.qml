import QtQuick

// Same cropped app-icon geometry as ios/Shared/PacemanMark.swift.
Item {
  id: root
  property color ink: "white"
  implicitWidth: 24
  implicitHeight: 24
  readonly property real unit: Math.min(width, height) / 720
  Item {
    width: 720 * root.unit
    height: 720 * root.unit
    anchors.centerIn: parent
    Rectangle {
      // Qt's border sits inside its rectangle; include the half-stroke on each side.
      x: 66 * root.unit; y: 135 * root.unit
      width: 588 * root.unit; height: 476 * root.unit
      radius: 168 * root.unit
      color: "transparent"
      border.color: root.ink
      border.width: 28 * root.unit
      antialiasing: true
    }
    Rectangle {
      x: 346 * root.unit; y: 66 * root.unit
      width: 28 * root.unit; height: 83 * root.unit
      radius: width / 2; color: root.ink
    }
    Rectangle {
      x: 327 * root.unit; y: 12 * root.unit
      width: 66 * root.unit; height: width
      radius: width / 2; color: root.ink
      antialiasing: true
    }
    Repeater {
      model: [252, 424]
      Rectangle {
        required property real modelData
        x: modelData * root.unit; y: 314 * root.unit
        width: 44 * root.unit; height: 98 * root.unit
        radius: width / 2; color: root.ink
        antialiasing: true
      }
    }
    Repeater {
      model: [16, 672]
      Rectangle {
        required property real modelData
        x: modelData * root.unit; y: 316 * root.unit
        width: 32 * root.unit; height: 115 * root.unit
        radius: width / 2; color: root.ink
        antialiasing: true
      }
    }
  }
}
