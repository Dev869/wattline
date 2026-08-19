// Renders AppIcon.icns: a rounded-square badge with a bicycle glyph.
// Uses the system symbol so the shape matches the menu bar icon exactly.

import AppKit

func render(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS icons are a squircle inset from the canvas, not edge to edge.
    let inset = size * 0.08
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: size * 0.225, yRadius: size * 0.225)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.30, blue: 0.62, alpha: 1),
    ])!
    squircle.addClip()
    gradient.draw(in: body, angle: -90)

    // A soft highlight across the top keeps it from looking like flat plastic.
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    sheen.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
               angle: -90)

    if let symbol = NSImage(systemSymbolName: "bicycle", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size * 0.46, weight: .regular)) {
        // Tint inside its own canvas: a sourceAtop fill on the main one would
        // paint straight over the squircle, since that is already opaque.
        let white = NSImage(size: symbol.size)
        white.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        white.unlockFocus()

        white.draw(in: NSRect(
            x: rect.midX - symbol.size.width / 2,
            y: rect.midY - symbol.size.height / 2,
            width: symbol.size.width,
            height: symbol.size.height
        ))
    }

    image.unlockFocus()
    return image
}

let out = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

for (size, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
] {
    let image = render(CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("iconset written")
