// Generates VoiceKey's app icon. Run: swift MakeIcon.swift
// Vector-drawn at every size, so it stays crisp from 16px to 1024px.
import AppKit

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Apple's squircle is close enough to a rounded rect at icon scale.
func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size S: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)

    // macOS icons sit inside the canvas with breathing room.
    let inset = S * 0.094
    let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = plate.width * 0.2237

    // soft drop shadow under the plate
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: hex(0x2A1B3D, 0.28))
    ctx.addPath(squircle(plate, radius))
    ctx.setFillColor(hex(0xF6C7B6))
    ctx.fillPath()
    ctx.restoreGState()

    // warm peach -> lilac gradient
    ctx.saveGState()
    ctx.addPath(squircle(plate, radius))
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [hex(0xFFC49A), hex(0xF08CA8), hex(0x9A85DC)] as CFArray,
                          locations: [0, 0.52, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

    // one soft light bloom, top-left — keeps it from looking flat
    let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [hex(0xFFFFFF, 0.30), hex(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(bloom,
        startCenter: CGPoint(x: plate.minX + plate.width * 0.28, y: plate.maxY - plate.height * 0.2),
        startRadius: 0,
        endCenter: CGPoint(x: plate.minX + plate.width * 0.28, y: plate.maxY - plate.height * 0.2),
        endRadius: plate.width * 0.5, options: [])
    ctx.restoreGState()

    // ---- microphone, cream, hand-drawn weight ----
    let cx = plate.midX
    let cream = hex(0xFFF7EE)
    let ink = hex(0x6B4C7A, 0.16)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.008), blur: S * 0.022, color: ink)

    // capsule body
    let bw = plate.width * 0.235
    let bh = plate.height * 0.375
    let body = CGRect(x: cx - bw / 2, y: plate.midY - bh * 0.18, width: bw, height: bh)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
    ctx.setFillColor(cream)
    ctx.fillPath()

    // cradle arc
    let lw = plate.width * 0.072
    let ar = bw * 0.78
    ctx.setStrokeColor(cream)
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: cx, y: body.minY + bh * 0.16), radius: ar,
               startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()

    // stem + base
    let stemTop = body.minY + bh * 0.16 - ar
    ctx.move(to: CGPoint(x: cx, y: stemTop))
    ctx.addLine(to: CGPoint(x: cx, y: stemTop - plate.height * 0.075))
    ctx.strokePath()
    ctx.setLineWidth(lw * 0.92)
    ctx.move(to: CGPoint(x: cx - plate.width * 0.105, y: stemTop - plate.height * 0.075))
    ctx.addLine(to: CGPoint(x: cx + plate.width * 0.105, y: stemTop - plate.height * 0.075))
    ctx.strokePath()
    ctx.restoreGState()

    // ---- sound bars flanking the mic ----
    let barW = plate.width * 0.052
    let heights: [CGFloat] = [0.17, 0.095]
    for (i, h) in heights.enumerated() {
        let dx = plate.width * (0.255 + 0.10 * CGFloat(i))
        for sign in [-1.0, 1.0] as [CGFloat] {
            let r = CGRect(x: cx + sign * dx - barW / 2, y: plate.midY + bh * 0.04 - plate.height * h / 2,
                           width: barW, height: plate.height * h)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2,
                               transform: nil))
            ctx.setFillColor(hex(0xFFF7EE, i == 0 ? 0.92 : 0.55))
            ctx.fillPath()
        }
    }

    return ctx.makeImage()!
}

// ---- write the iconset ----

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let img = drawIcon(size: CGFloat(px))
        let rep = NSBitmapImageRep(cgImage: img)
        rep.size = NSSize(width: px, height: px)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: out.appendingPathComponent(name))
    }
}
print("wrote AppIcon.iconset")
