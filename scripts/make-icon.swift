// Renders the app icon (light, dark, tinted) into the asset catalog:
//   swiftc -O scripts/make-icon.swift -o build/make-icon && build/make-icon App/Resources/Assets.xcassets/AppIcon.appiconset

import AppKit

let size = 1024.0
let out = CommandLine.arguments[1]

func render(_ name: String, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

func gradient(_ ctx: CGContext, _ colors: [NSColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func symbol(_ name: String, points: CGFloat, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func drawGlyph(_ ctx: CGContext, color: NSColor, shadow: Bool) {
    // Concentric "touch" ripples behind the fingertip.
    let tip = CGPoint(x: 484, y: 655)
    for (i, r) in [150.0, 230.0].enumerated() {
        ctx.setStrokeColor(color.withAlphaComponent(i == 0 ? 0.55 : 0.28).cgColor)
        ctx.setLineWidth(i == 0 ? 26 : 20)
        ctx.strokeEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
    }
    let hand = symbol("hand.point.up.fill", points: 470, color: color)
    let s = hand.size
    let rect = CGRect(x: 512 - s.width / 2 + 30, y: 470 - s.height / 2 - 40, width: s.width, height: s.height)
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor.black.withAlphaComponent(0.28).cgColor) }
    hand.draw(in: rect)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // A sparkle: the "agent".
    let sparkle = symbol("sparkle", points: 170, color: color)
    sparkle.draw(in: CGRect(x: 690, y: 690, width: sparkle.size.width, height: sparkle.size.height))
}

let start = NSColor(srgbRed: 0.31, green: 0.36, blue: 1.0, alpha: 1)
let end = NSColor(srgbRed: 0.64, green: 0.36, blue: 1.0, alpha: 1)

render("AppIcon") { ctx in
    gradient(ctx, [start, end], from: CGPoint(x: 0, y: size), to: CGPoint(x: size, y: 0))
    // Soft top-left highlight.
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: 200, y: 900), startRadius: 0, endCenter: CGPoint(x: 200, y: 900), endRadius: 700, options: [])
    drawGlyph(ctx, color: .white, shadow: true)
}

render("AppIcon-Dark") { ctx in
    gradient(ctx, [NSColor(srgbRed: 0.07, green: 0.07, blue: 0.14, alpha: 1), NSColor(srgbRed: 0.03, green: 0.03, blue: 0.07, alpha: 1)],
             from: CGPoint(x: 0, y: size), to: CGPoint(x: size, y: 0))
    // Glyph in the brand gradient: draw white glyph into a mask layer, then fill with gradient.
    let layer = CGLayer(ctx, size: CGSize(width: size, height: size), auxiliaryInfo: nil)!
    let lctx = layer.context!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: lctx, flipped: false)
    drawGlyph(lctx, color: .white, shadow: false)
    lctx.setBlendMode(.sourceIn)
    gradient(lctx, [NSColor(srgbRed: 0.45, green: 0.5, blue: 1, alpha: 1), NSColor(srgbRed: 0.75, green: 0.5, blue: 1, alpha: 1)],
             from: CGPoint(x: 0, y: size), to: CGPoint(x: size, y: 0))
    NSGraphicsContext.restoreGraphicsState()
    ctx.draw(layer, at: .zero)
}

render("AppIcon-Tinted") { ctx in
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    drawGlyph(ctx, color: .white, shadow: false)
}
