import AppKit
import CoreGraphics

let dev = CommandLine.arguments.contains("--dev")
let output = CommandLine.arguments.first { $0 != CommandLine.arguments[0] && $0 != "--dev" }!
// Render vector artwork into an opaque RGB buffer; no display context is needed.
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: alpha)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
let body = CGMutablePath()
body.addPath(rounded(CGRect(x: 232, y: 260, width: 560, height: 448), 154))
for x in [404.0, 576.0] {
    body.addPath(rounded(CGRect(x: x, y: 445, width: 44, height: 98), 22))
}

if dev {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(25, 151, 236), rgb(20, 65, 145)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024),
        end: CGPoint(x: 1024, y: 0), options: [])
    context.setStrokeColor(rgb(216, 242, 255, 0.13))
    context.setLineWidth(5)
    for diameter in [760.0, 970.0, 1180.0] {
        context.strokeEllipse(in: CGRect(x: 512 - diameter / 2,
            y: 512 - diameter / 2, width: diameter, height: diameter))
    }
} else {
    // Fixed release artwork follows the Ayu default: navy and yellow.
    context.setFillColor(rgb(31, 36, 48))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
}
context.setFillColor(dev ? rgb(245, 250, 255) : rgb(255, 204, 102))
context.addPath(body)
context.drawPath(using: .eoFill)
if dev {
    // A half-blue robot with a light grid echoes TestFlight's solid/wireframe mix.
    context.saveGState()
    context.clip(to: CGRect(x: 512, y: 0, width: 512, height: 1024))
    context.addPath(body)
    context.clip(using: .evenOdd)
    context.setFillColor(rgb(168, 220, 251))
    context.fill(CGRect(x: 512, y: 260, width: 280, height: 448))
    context.setStrokeColor(rgb(44, 139, 204, 0.5))
    context.setLineWidth(5)
    for x in stride(from: 512.0, through: 800.0, by: 56.0) {
        context.move(to: CGPoint(x: x, y: 250))
        context.addLine(to: CGPoint(x: x, y: 710))
    }
    for y in stride(from: 260.0, through: 710.0, by: 56.0) {
        context.move(to: CGPoint(x: 500, y: y))
        context.addLine(to: CGPoint(x: 800, y: y))
    }
    context.strokePath()
    context.restoreGState()
}
context.fill(CGRect(x: 498, y: 694, width: 28, height: 118))
context.fillEllipse(in: CGRect(x: 479, y: 779, width: 66, height: 66))
for x in [162.0, 818.0] {
    context.addPath(rounded(CGRect(x: x, y: 445, width: 44, height: 98), 22)); context.fillPath()
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
