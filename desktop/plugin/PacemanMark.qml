import QtQuick

// Same cropped app-icon geometry as ios/Shared/PacemanMark.swift.
Item {
  id: root
  property color ink: "white"
  implicitWidth: 24
  implicitHeight: 24
  readonly property real unit: Math.min(width, height) / 720
  onInkChanged: face.requestPaint()
  Item {
    width: 720 * root.unit
    height: 720 * root.unit
    anchors.centerIn: parent
    Canvas {
      id: face
      anchors.fill: parent
      renderTarget: Canvas.Image
      function roundedRect(ctx, x, y, w, h, r) {
        ctx.beginPath()
        ctx.moveTo(x + r, y)
        ctx.lineTo(x + w - r, y)
        ctx.quadraticCurveTo(x + w, y, x + w, y + r)
        ctx.lineTo(x + w, y + h - r)
        ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
        ctx.lineTo(x + r, y + h)
        ctx.quadraticCurveTo(x, y + h, x, y + h - r)
        ctx.lineTo(x, y + r)
        ctx.quadraticCurveTo(x, y, x + r, y)
        ctx.closePath()
      }
      onPaint: {
        const ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        ctx.save()
        ctx.scale(root.unit, root.unit)
        ctx.fillStyle = root.ink
        roundedRect(ctx, 80, 149, 560, 448, 154)
        ctx.fill()
        ctx.globalCompositeOperation = "destination-out"
        for (const x of [252, 424]) {
          roundedRect(ctx, x, 314, 44, 98, 22)
          ctx.fill()
        }
        ctx.restore()
      }
    }
    Rectangle {
      x: 346 * root.unit; y: 45 * root.unit
      width: 28 * root.unit; height: 118 * root.unit
      color: root.ink
    }
    Rectangle {
      x: 327 * root.unit; y: 12 * root.unit
      width: 66 * root.unit; height: width
      radius: width / 2; color: root.ink
      antialiasing: true
    }
    Repeater {
      model: [10, 666]
      Rectangle {
        required property real modelData
        x: modelData * root.unit; y: 314 * root.unit
        width: 44 * root.unit; height: 98 * root.unit
        radius: width / 2; color: root.ink
        antialiasing: true
      }
    }
  }
}
