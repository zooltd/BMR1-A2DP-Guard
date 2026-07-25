// makeicon — renders Support/AppIcon.icns for BMR1 Guard.
// Blue gradient squircle + white hifispeaker glyph + green checkmark badge.
// Usage: swift makeicon.swift <output-dir>   (writes AppIcon.iconset/ + AppIcon.icns)
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetURL = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func tinted(_ symbol: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let conf = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(conf) else { return nil }
    let img = NSImage(size: sym.size)
    img.lockFocus()
    sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}

/// Draw the 1024-canvas design scaled into a pixel-exact bitmap.
func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px) / 1024.0

    // macOS icon grid: squircle occupies ~80% of the canvas.
    let inset = 100.0 * s
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGradient(starting: NSColor(calibratedRed: 0.38, green: 0.67, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.55, alpha: 1))!
        .draw(in: squircle, angle: -90)

    // Speaker glyph, centered, nudged up to make room for the badge.
    if let speaker = tinted("hifispeaker.fill", pointSize: 460, weight: .medium, color: .white) {
        let target = NSRect(x: rect.midX - 260 * s, y: rect.midY - 250 * s,
                            width: 520 * s, height: 520 * s)
        let ar = speaker.size.width / speaker.size.height
        var draw = target
        if ar < 1 { draw.size.width = target.height * ar; draw.origin.x = target.midX - draw.width / 2 }
        else      { draw.size.height = target.width / ar; draw.origin.y = target.midY - draw.height / 2 }
        speaker.draw(in: draw, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // Green checkmark badge, bottom-right.
    let badgeR = 130.0 * s
    let badgeCenter = NSPoint(x: rect.maxX - 150 * s, y: rect.minY + 150 * s)
    let badgeRect = NSRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR,
                           width: badgeR * 2, height: badgeR * 2)
    NSColor.white.set()
    NSBezierPath(ovalIn: badgeRect.insetBy(dx: -14 * s, dy: -14 * s)).fill()
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).set()
    NSBezierPath(ovalIn: badgeRect).fill()
    if let check = tinted("checkmark", pointSize: 150, weight: .heavy, color: .white) {
        let cw = badgeR * 1.15
        let ch = cw * check.size.height / check.size.width
        check.draw(in: NSRect(x: badgeCenter.x - cw / 2, y: badgeCenter.y - ch / 2, width: cw, height: ch),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
    return rep
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    let rep = render(px: px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: iconsetURL.appendingPathComponent("\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path,
                  "-o", URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(outDir)/AppIcon.icns" : "iconutil failed")
exit(task.terminationStatus)
