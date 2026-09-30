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
        colors: [rgb(61, 183, 242), rgb(60, 99, 239)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024),
        end: CGPoint(x: 1024, y: 0), options: [])
    // TestFlight's broad, quiet blueprint grid reads at Home Screen size.
    context.setStrokeColor(rgb(219, 244, 255, 0.27))
    context.setLineWidth(5)
    for position in [256.0, 512.0, 768.0] {
        context.move(to: CGPoint(x: position, y: 0))
        context.addLine(to: CGPoint(x: position, y: 1024))
        context.move(to: CGPoint(x: 0, y: position))
        context.addLine(to: CGPoint(x: 1024, y: position))
    }
    context.strokePath()
} else {
    // Fixed release artwork follows the Ayu default: navy and yellow.
    context.setFillColor(rgb(31, 36, 48))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
}
context.setFillColor(dev ? rgb(245, 250, 255) : rgb(255, 204, 102))
context.addPath(body)
context.drawPath(using: .eoFill)
context.fill(CGRect(x: 498, y: 694, width: 28, height: 118))
context.fillEllipse(in: CGRect(x: 479, y: 779, width: 66, height: 66))
for x in [162.0, 818.0] {
    context.addPath(rounded(CGRect(x: x, y: 445, width: 44, height: 98), 22)); context.fillPath()
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
