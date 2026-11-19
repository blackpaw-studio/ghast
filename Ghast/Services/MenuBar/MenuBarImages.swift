import AppKit

/// The menu bar extra's images: Ghast's ghost as a template, and coloured status dots (never
/// templates, so the menu keeps their colours).
@MainActor
enum MenuBarImages {
    /// Measured from MenuBar.png: a 13 × 15 pt ghost with two eyes and three lobes, in a 16 pt box.
    static let ghost: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let left: CGFloat = 1.5, right: CGFloat = 14.5, top: CGFloat = 0.5, lobeTop: CGFloat = 13.3
            let radius = (right - left) / 2
            let lobe = (right - left) / 3
            let body = NSBezierPath()
            body.move(to: NSPoint(x: left, y: lobeTop))
            body.line(to: NSPoint(x: left, y: top + radius))
            body.appendArc(withCenter: NSPoint(x: left + radius, y: top + radius), radius: radius, startAngle: 180, endAngle: 0, clockwise: false)
            body.line(to: NSPoint(x: right, y: lobeTop))
            // Three round lobes along the bottom, right to left.
            for index in (0..<3).reversed() {
                let center = NSPoint(x: left + lobe * (CGFloat(index) + 0.5), y: lobeTop)
                body.appendArc(withCenter: center, radius: lobe / 2, startAngle: 0, endAngle: 180, clockwise: false)
            }
            body.close()
            for eyeX in [6.1, 9.9] as [CGFloat] {
                body.appendOval(in: NSRect(x: eyeX - 1.05, y: 5.85, width: 2.1, height: 2.8))
            }
            body.windingRule = .evenOdd
            NSColor.black.setFill()
            body.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ghast"
        return image
    }()

    /// The dot's box: an 8 pt dot with room for the running halo, so names line up.
    private static let box: CGFloat = 12
    private static let dot: CGFloat = 8

    private static var cache: [MenuBarDot: NSImage] = [:]

    static func dot(_ kind: MenuBarDot) -> NSImage {
        if let cached = cache[kind] { return cached }
        let image = NSImage(size: NSSize(width: box, height: box), flipped: false) { rect in
            let dotRect = rect.insetBy(dx: (box - dot) / 2, dy: (box - dot) / 2)
            switch kind {
            case .idle:
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            case .error:
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            case .running:
                NSColor.systemOrange.withAlphaComponent(FocusMetrics.runningHaloOpacity).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            case .hollow:
                let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                NSColor.tertiaryLabelColor.setStroke()
                ring.stroke()
            case .standby:
                let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.setLineDash([2, 1.5], count: 2, phase: 0)
                NSColor.secondaryLabelColor.setStroke()
                ring.stroke()
            }
            return true
        }
        let bitmap = rasterized(image)
        cache[kind] = bitmap
        return bitmap
    }

    /// Menus draw bitmap images only, so the drawing handler is rendered at 1x and 2x.
    private static func rasterized(_ image: NSImage) -> NSImage {
        let result = NSImage(size: image.size)
        for scale in [1, 2] as [CGFloat] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(image.size.width * scale),
                pixelsHigh: Int(image.size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            result.addRepresentation(rep)
        }
        result.isTemplate = false
        return result
    }
}
