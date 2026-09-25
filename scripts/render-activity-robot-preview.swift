import AppKit
import CoreGraphics
import Foundation

// Design preview only. The outer geometry matches scripts/make-app-icon.swift.
// Render at 3x to inspect the current 31 pt phone glyph and smaller previews.
enum Expression: String, CaseIterable {
    case working, needsInput = "needs-input", finished
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ context: CGContext, _ name: String) throws {
    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: output.appendingPathComponent(name))
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func cutEyes(_ ctx: CGContext, _ expression: Expression) {
    ctx.setBlendMode(.clear)
    // The happy face needs a wider stance than the neutral logo eyes.
    let centers = expression == .finished ? [382.0, 642.0] : [426.0, 598.0]
    for center in centers {
        switch expression {
        case .working:
            ctx.addPath(rounded(CGRect(x: center - 22, y: 445, width: 44, height: 98), 22))
        case .needsInput:
            let eye = CGMutablePath()
            eye.move(to: CGPoint(x: center - 61, y: 474))
            eye.addLine(to: CGPoint(x: center, y: 543))
            eye.addLine(to: CGPoint(x: center + 61, y: 474))
            eye.addLine(to: CGPoint(x: center + 39, y: 452))
            eye.addLine(to: CGPoint(x: center, y: 497))
            eye.addLine(to: CGPoint(x: center - 39, y: 452))
            eye.closeSubpath()
            ctx.addPath(eye)
        case .finished:
            let arc = CGMutablePath()
            arc.move(to: CGPoint(x: center - 65, y: 477))
            arc.addQuadCurve(to: CGPoint(x: center + 65, y: 477),
                             control: CGPoint(x: center, y: 600))
            ctx.addPath(arc.copy(strokingWithWidth: 31, lineCap: .round,
                                 lineJoin: .round, miterLimit: 10))
        }
        ctx.fillPath()
    }
    ctx.setBlendMode(.normal)
}

func glyph(_ expression: Expression, pixels: Int, ink: CGColor) -> CGImage {
    let ctx = context(pixels, pixels)
    ctx.scaleBy(x: CGFloat(pixels) / 720, y: CGFloat(pixels) / 720)
    ctx.translateBy(x: -152, y: -137)
    ctx.setFillColor(ink)
    ctx.addPath(rounded(CGRect(x: 232, y: 260, width: 560, height: 448), 154))
    ctx.fillPath()
    ctx.fill(CGRect(x: 498, y: 694, width: 28, height: 118))
    ctx.fillEllipse(in: CGRect(x: 479, y: 779, width: 66, height: 66))
    for x in [162.0, 818.0] {
        ctx.addPath(rounded(CGRect(x: x, y: 445, width: 44, height: 98), 22))
        ctx.fillPath()
    }
    cutEyes(ctx, expression)
    return ctx.makeImage()!
}

func drawTile(_ expression: Expression, at time: Double,
              glyphPoints: Int, canvas: Int, theme: String) -> CGContext {
    let factor = 3
    let ctx = context(canvas, canvas)
    let background = color(theme == "ayu" ? 0x282E3B : 0x202A23)
    let ink = color(theme == "ayu" ? 0xFFCC66 : 0xA8D2B6)
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    let pixels = glyphPoints * factor
    let mark = glyph(expression, pixels: pixels, ink: ink)
    let pulse = (1 - cos(time * .pi / 1.3)) / 2
    let bounceTime = time.truncatingRemainder(dividingBy: 1)
    let bounce = bounceTime < 0.64 ? (1 - cos(bounceTime * .pi / 0.32)) / 2 : 0
    let sway = sin(time * 2 * .pi / 4.2)
    let opacity = expression == .working ? 1 - pulse * (155.0 / 255) : 1
    let xOffset = expression == .finished ? sway * 2 * Double(factor) : 0
    let yOffset = expression == .needsInput ? bounce * 3 * Double(factor) : 0
    let angle = expression == .finished ? sway * 4 * .pi / 180 : 0

    ctx.saveGState()
    ctx.setAlpha(opacity)
    ctx.translateBy(x: CGFloat(canvas) / 2 + xOffset,
                    y: CGFloat(canvas) / 2 + yOffset)
    ctx.rotate(by: angle)
    ctx.draw(mark, in: CGRect(x: -pixels / 2, y: -pixels / 2,
                              width: pixels, height: pixels))
    ctx.restoreGState()
    return ctx
}

for theme in ["ayu", "paceman"] {
    for expression in Expression.allCases {
        for (points, canvas) in [(31, 180), (11, 96), (120, 440)] {
            try save(drawTile(expression, at: 0, glyphPoints: points,
                              canvas: canvas, theme: theme),
                     "\(theme)-\(expression.rawValue)-\(points)pt.png")
        }
    }
}

let durations: [(Expression, Double)] = [(.working, 2.6), (.needsInput, 1), (.finished, 4.2)]
let fps = 15
for (expression, duration) in durations {
    let directory = output.appendingPathComponent("frames-\(expression.rawValue)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for frame in 0..<Int(duration * Double(fps)) {
        let ctx = drawTile(expression, at: Double(frame) / Double(fps),
                           glyphPoints: 31, canvas: 180, theme: "ayu")
        let image = ctx.makeImage()!
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent(String(format: "%03d.png", frame)))
    }
}
