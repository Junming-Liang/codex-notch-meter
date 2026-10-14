import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Expected PNG output path") }
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.05, green: 0.075, blue: 0.095, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220).fill()
let notch = NSBezierPath(roundedRect: NSRect(x: 310, y: 370, width: 404, height: 590), xRadius: 100, yRadius: 100)
NSColor.black.setFill(); notch.fill()
for left in [true, false] {
    let path = NSBezierPath()
    let x: CGFloat = left ? 279 : 745
    path.move(to: NSPoint(x: x, y: 850))
    path.line(to: NSPoint(x: x, y: 447))
    path.curve(to: NSPoint(x: left ? 385 : 639, y: 339), controlPoint1: NSPoint(x: x, y: 373), controlPoint2: NSPoint(x: left ? 315 : 709, y: 339))
    path.line(to: NSPoint(x: left ? 486 : 538, y: 339))
    path.lineWidth = 24; path.lineCapStyle = .round
    (left ? NSColor(calibratedRed: 0.31, green: 0.91, blue: 0.72, alpha: 1) : NSColor(calibratedRed: 0.35, green: 0.67, blue: 1, alpha: 1)).setStroke()
    path.stroke()
}
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not render icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
