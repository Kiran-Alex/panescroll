// Draws Reel's app icon (concept A, "Strip") and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = size / 1024 // design on a 1024 grid (Apple: 824 pt body, 100 pt margin)

    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: CGRect(x: x * k, y: y * k, width: w * k, height: h * k), xRadius: r * k, yRadius: r * k)
    }

    // Body with a soft drop shadow.
    let body = rr(100, 100, 824, 824, 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    NSColor(red: 0.28, green: 0.29, blue: 0.82, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.40, green: 0.46, blue: 1.00, alpha: 1),
               ending: NSColor(red: 0.20, green: 0.15, blue: 0.60, alpha: 1))!.draw(in: body, angle: -90)

    // Neighbouring windows, cut off by the icon edge; focused window in front.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSColor.white.withAlphaComponent(0.36).setFill()
    rr(40, 300, 210, 424, 48).fill()
    rr(774, 300, 210, 424, 48).fill()
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(red: 0.1, green: 0.05, blue: 0.4, alpha: 0.45)
    glow.shadowBlurRadius = 30 * k
    glow.shadowOffset = NSSize(width: 0, height: -12 * k)
    glow.set()
    NSColor.white.setFill()
    rr(312, 262, 400, 500, 60).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
