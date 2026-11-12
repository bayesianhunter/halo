// SPDX-License-Identifier: GPL-3.0-only
// Renders the Halo app icon (a glowing ring with a dot towards the upper right) into an .icns.
// Usage: swift scripts/make-icon.swift packaging/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "packaging/AppIcon.icns")
let TAU = CGFloat.pi * 2
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func drawIcon(_ context: CGContext, size: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Full bleed: macOS 26 masks a square icon to its own squircle and adds the glass edge, while an icon
    // that draws its own squircle is shrunk onto a grey plate.
    let s = size, u = s / 100
    // Flip to y-down so the geometry matches the canvas design.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    context.saveGState()
    let background = CGGradient(colorsSpace: space, colors: [rgb(0x2b3aa8), rgb(0x0b1033)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: .zero, end: CGPoint(x: s, y: s), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x5082ff, 0.55), rgb(0x5082ff, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 50 * u, y: 50 * u), startRadius: 0,
                               endCenter: CGPoint(x: 50 * u, y: 50 * u), endRadius: 48 * u, options: [])

    // The ring: a gradient stroke with a cool glow.
    let ringRect = CGRect(x: 25 * u, y: 25 * u, width: 50 * u, height: 50 * u)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 9 * u, color: rgb(0x8cd2ff, 0.9))
    context.setLineWidth(7 * u)
    context.addEllipse(in: ringRect)
    context.replacePathWithStrokedPath()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.clip()
    let ring = CGGradient(colorsSpace: space, colors: [rgb(0x6f86ff), rgb(0xb9ecff), rgb(0xffffff)] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(ring, start: CGPoint(x: 25 * u, y: 75 * u), end: CGPoint(x: 75 * u, y: 25 * u), options: [])
    context.endTransparencyLayer()
    context.restoreGState()

    // The dot, set inside the ring towards the upper right.
    let angle = -50 * CGFloat.pi / 180, dot = 5.8 * u
    let center = CGPoint(x: 50 * u + 12.5 * u * cos(angle), y: 50 * u + 12.5 * u * sin(angle))
    context.setShadow(offset: .zero, blur: 14 * u, color: rgb(0xa0dcff, 0.95))
    context.setFillColor(rgb(0xffffff))
    context.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // A faint sheen across the top, as on Apple's icons.
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xffffff, 0.18), rgb(0xffffff, 0)] as CFArray, locations: [0, 0.45])!
    context.drawLinearGradient(sheen, start: .zero, end: CGPoint(x: 0, y: s), options: [])
    context.restoreGState()
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Halo-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(NSGraphicsContext.current!.cgContext, size: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
