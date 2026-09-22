#!/usr/bin/env swift
// Renders the app icon in two forms, both beside `output`:
// - AppIcon.icns: a rounded square with a sparkle glyph on Apple's macOS grid (macOS 14 and 15, and builds without actool).
// - AppIcon.icon: an Icon Composer bundle (gradient fill plus a white sparkle layer) that
//   scripts/build.sh compiles with `xcrun actool`, so macOS 26 draws a native Liquid Glass icon.
// Usage: swift scripts/make-icon.swift [output.icns]
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = NSTemporaryDirectory() + "JevIcon-\(getpid()).iconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// Apple's macOS grid: an 824/1024 body centred on the canvas, leaving room for the shadow.
func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let body = size * 824 / 1024
    let square = NSRect(x: (size - body) / 2, y: (size - body) / 2, width: body, height: body)
    let path = NSBezierPath(roundedRect: square, xRadius: body * 0.225, yRadius: body * 0.225)
    // Solid fill casts the shadow; the gradient then paints over it unshadowed.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSColor(calibratedRed: 0.25, green: 0.42, blue: 0.96, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.38, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.98, alpha: 1)])!
        .draw(in: path, angle: -60)
    if let glyph = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: square.width * 0.5, weight: .semibold)) {
        let tinted = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
        }
        let rect = NSRect(x: square.midX - tinted.size.width / 2, y: square.midY - tinted.size.height / 2,
                          width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: rect)
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", output]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
print(output)

/// Icon Composer bundle: the system supplies the squircle, shadow, and glass; the layer is the glyph only.
let composer = (output as NSString).deletingLastPathComponent + "/AppIcon.icon"
try FileManager.default.createDirectory(atPath: composer + "/Assets", withIntermediateDirectories: true)
let layer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
if let glyph = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 500, weight: .semibold)) {
    let tinted = NSImage(size: glyph.size, flipped: false) { rect in
        glyph.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
    }
    tinted.draw(in: NSRect(x: (1024 - glyph.size.width) / 2, y: (1024 - glyph.size.height) / 2,
                           width: glyph.size.width, height: glyph.size.height))
}
NSGraphicsContext.restoreGraphicsState()
try layer.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: composer + "/Assets/sparkle.png"))
let manifest = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.38000,0.30000,0.95000,1.00000",
      "srgb:0.13000,0.55000,0.98000,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "sparkle.png",
          "name" : "sparkle"
        }
      ]
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}

"""
try manifest.write(toFile: composer + "/icon.json", atomically: true, encoding: .utf8)
print(composer)
