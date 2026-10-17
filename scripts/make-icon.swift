import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let unit = CGFloat(pixels) / 1024
        context.cgContext.scaleBy(x: unit, y: unit)
        let bounds = NSRect(x: 58, y: 58, width: 908, height: 908)
        let background = NSBezierPath(roundedRect: bounds, xRadius: 202, yRadius: 202)
        NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.35, alpha: 1),
                   ending: NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.12, alpha: 1))!.draw(in: background, angle: -70)
        NSColor(calibratedRed: 0.56, green: 0.87, blue: 0.80, alpha: 1).setStroke()
        for rect in [NSRect(x: 230, y: 230, width: 564, height: 564), NSRect(x: 372, y: 230, width: 280, height: 564), NSRect(x: 230, y: 380, width: 564, height: 264)] {
            let ring = NSBezierPath(ovalIn: rect); ring.lineWidth = 25; ring.stroke()
        }
        let axis = NSBezierPath(); axis.move(to: NSPoint(x: 512, y: 200)); axis.line(to: NSPoint(x: 512, y: 824)); axis.lineWidth = 20; axis.stroke()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 704, y: 672, width: 74, height: 74)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
