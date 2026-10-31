import AppKit
import Foundation
let destination = CommandLine.arguments[1]
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let background = NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 205, yRadius: 205)
NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.23, blue: 0.3, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.09, blue: 0.16, alpha: 1))!.draw(in: background, angle: 90)
let blocks: [(NSRect, NSColor)] = [
    (NSRect(x: 167, y: 167, width: 300, height: 690), NSColor.systemTeal),
    (NSRect(x: 489, y: 497, width: 368, height: 360), NSColor.systemCyan),
    (NSRect(x: 489, y: 167, width: 170, height: 308), NSColor.systemIndigo),
    (NSRect(x: 681, y: 167, width: 176, height: 180), NSColor.systemBlue),
    (NSRect(x: 681, y: 369, width: 176, height: 106), NSColor.systemMint)
]
for (rect, color) in blocks {
    let path = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
    NSGradient(starting: color.blended(withFraction: 0.18, of: .white)!, ending: color)!.draw(in: path, angle: -55)
    NSColor.white.withAlphaComponent(0.22).setStroke(); path.lineWidth = 3; path.stroke()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
