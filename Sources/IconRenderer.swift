import AppKit

func renderBatteryIcon(level: Int, state: ChargeState) -> NSImage {
    let font   = sfRounded(size: 13, weight: .bold)
    let text   = "\(level)"
    let str    = NSAttributedString(string: text,
                                    attributes: [.font: font, .foregroundColor: NSColor.black,
                                                 .kern: -font.pointSize * 0.03])
    let tSize  = str.size()

    let hasSymbol   = state != .discharging
    let symW: CGFloat   = hasSymbol ? 7.5 : 0
    let symGap: CGFloat = hasSymbol ? 1   : 0

    let bodyH: CGFloat   = 13
    let minHPad: CGFloat = (text.count == 2 ? 4 : 3) - (hasSymbol ? 2 : 0)
    let contentW = tSize.width + symGap + symW
    let bodyW    = contentW + minHPad * 2
    let radius: CGFloat  = 3.5
    let nubGap: CGFloat  = 1
    let nubW: CGFloat    = 2
    let nubH: CGFloat    = 5

    let totalSize = NSSize(width: ceil(bodyW + nubGap + nubW), height: bodyH)
    let scale: CGFloat = 2
    let pw = Int(totalSize.width * scale)
    let ph = Int(totalSize.height * scale)

    guard let ctx = CGContext(
        data: nil, width: pw, height: ph,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return NSImage() }

    ctx.scaleBy(x: scale, y: scale)

    // Filled body
    ctx.setFillColor(CGColor.black)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: bodyW, height: bodyH),
                       cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()

    // Nub — all corners rounded 2 pt
    let nx = bodyW + nubGap
    let ny = (bodyH - nubH) / 2
    ctx.addPath(CGPath(roundedRect: CGRect(x: nx, y: ny, width: nubW, height: nubH),
                       cornerWidth: 2, cornerHeight: 2, transform: nil))
    ctx.fillPath()

    // Switch to destinationOut to punch out the content
    ctx.setBlendMode(.destinationOut)

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let startX   = (bodyW - contentW) / 2
    let baseline = (bodyH - font.capHeight) / 2 - 2.75
    str.draw(at: CGPoint(x: startX, y: baseline))

    if hasSymbol {
        NSColor.black.setFill()
        let symX = startX + tSize.width + symGap
        if state == .charging { drawLightning(x: symX, y: 1.5, w: symW, h: bodyH - 3) }
        else                  { drawPause   (x: symX, y: 1.5, w: symW, h: bodyH - 3) }
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { return NSImage() }
    let image = NSImage(cgImage: cgImage, size: totalSize)
    image.isTemplate = true
    return image
}

// MARK: - Symbols

private func drawLightning(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
    // bolt.svg viewBox 0 0 6 10, y-down → CGContext y-up
    let t = CGAffineTransform(a: w/6, b: 0, c: 0, d: -h/10, tx: x, ty: y + h)
    let p = CGMutablePath()
    p.move    (to: .init(x: 3.26842,    y: 0.228768),  transform: t)
    p.addCurve(to: .init(x: 2.87406,    y: 0.117046),
               control1: .init(x: 3.28568,   y: -0.00290141),
               control2: .init(x: 2.97704,   y: -0.0903385),  transform: t)
    p.addLine (to: .init(x: 0.0226811,  y: 5.85946),   transform: t)
    p.addCurve(to: .init(x: 0.208954,   y: 6.1674),
               control1: .init(x: -0.04742,  y: 6.00064),
               control2: .init(x: 0.053456,  y: 6.1674),      transform: t)
    p.addLine (to: .init(x: 2.77491,    y: 6.1674),    transform: t)
    p.addCurve(to: .init(x: 2.983,      y: 6.39569),
               control1: .init(x: 2.89637,   y: 6.1674),
               control2: .init(x: 2.99217,   y: 6.2725),      transform: t)
    p.addLine (to: .init(x: 2.73158,    y: 9.77123),   transform: t)
    p.addCurve(to: .init(x: 3.12594,    y: 9.88295),
               control1: .init(x: 2.71432,   y: 10.0029),
               control2: .init(x: 3.02296,   y: 10.0903),     transform: t)
    p.addLine (to: .init(x: 5.97732,    y: 4.14054),   transform: t)
    p.addCurve(to: .init(x: 5.79105,    y: 3.83259),
               control1: .init(x: 6.04742,   y: 3.99936),
               control2: .init(x: 5.94654,   y: 3.83259),     transform: t)
    p.addLine (to: .init(x: 3.22509,    y: 3.83259),   transform: t)
    p.addCurve(to: .init(x: 3.017,      y: 3.60431),
               control1: .init(x: 3.10363,   y: 3.83259),
               control2: .init(x: 3.00783,   y: 3.7275),      transform: t)
    p.addLine (to: .init(x: 3.26842,    y: 0.228768),  transform: t)
    p.closeSubpath()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.addPath(p)
    ctx.fillPath()
}

private func drawPause(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
    let bw: CGFloat = 2.5
    let gap: CGFloat = 1.5
    let offset = (w - bw * 2 - gap) / 2
    [x + offset, x + offset + bw + gap].forEach { bx in
        NSBezierPath(roundedRect: .init(x: bx, y: y, width: bw, height: h),
                     xRadius: 1, yRadius: 1).fill()
    }
}

func renderPlugIcon() -> NSImage {
    let size = CGSize(width: 18, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        guard let symbol = NSImage(systemSymbolName: "powerplug", accessibilityDescription: nil) else { return false }
        symbol.draw(in: rect)
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Font

private func sfRounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let desc = base.fontDescriptor.withDesign(.rounded) {
        return NSFont(descriptor: desc, size: size) ?? base
    }
    return base
}
