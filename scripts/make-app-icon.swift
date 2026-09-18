import AppKit
import CoreGraphics

// Render vector artwork into an opaque RGB buffer; no display context is needed.
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.961, green: 0.957, blue: 0.937, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
let ink = CGColor(red: 0.271, green: 0.396, blue: 0.329, alpha: 1)
context.setFillColor(ink)
context.setStrokeColor(ink)
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
context.addPath(rounded(CGRect(x: 232, y: 260, width: 560, height: 448), 154))
context.setLineWidth(28)
context.strokePath()
for x in [404.0, 576.0] {
    context.addPath(rounded(CGRect(x: x, y: 445, width: 44, height: 98), 22)); context.fillPath()
}
context.addPath(rounded(CGRect(x: 498, y: 708, width: 28, height: 83), 14)); context.fillPath()
context.fillEllipse(in: CGRect(x: 479, y: 779, width: 66, height: 66))
for x in [168.0, 824.0] {
    context.addPath(rounded(CGRect(x: x, y: 426, width: 32, height: 115), 16)); context.fillPath()
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
