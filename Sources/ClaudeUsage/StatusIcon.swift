import AppKit

/// Иконки строки меню. Везде действует одно правило:
/// внешний/верхний элемент — 5-часовая сессия, внутренний/нижний — недельная квота.
enum StatusIcon {

    private static let height: CGFloat = 18

    // Кольца стали заметно толще: 2,2 pt вместо 1,55 — в строке меню тонкие дуги терялись.
    private static let outerRadius: CGFloat = 7.1
    private static let innerRadius: CGFloat = 3.8
    private static let ringWidth: CGFloat = 2.2
    private static let trackAlpha: CGFloat = 0.3

    static func image(kind: IconKind, session: Double, week: Double, tint: NSColor?) -> NSImage? {
        switch kind {
        case .none: return nil
        case .ring: return rings(session: session, week: week, tint: tint)
        case .bars: return bars(session: session, week: week, tint: tint)
        case .battery: return battery(session: session, week: week, tint: tint)
        case .dots: return dots(session: session, week: week, tint: tint)
        }
    }

    // MARK: - Кольца

    static func rings(session: Double, week: Double, tint: NSColor?) -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            let base = tint ?? .black
            track(center: center, radius: outerRadius, color: base)
            track(center: center, radius: innerRadius, color: base)
            arc(center: center, radius: outerRadius, fraction: session / 100, color: base)
            arc(center: center, radius: innerRadius, fraction: week / 100,
                color: base.withAlphaComponent(tint == nil ? 0.65 : 0.8))
            return true
        }
        image.isTemplate = (tint == nil)
        return image
    }

    // MARK: - Две полосы

    static func bars(session: Double, week: Double, tint: NSColor?) -> NSImage {
        let size = NSSize(width: 19, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let base = tint ?? .black
            let barHeight: CGFloat = 4.8
            let width: CGFloat = 17
            let x: CGFloat = 1
            bar(NSRect(x: x, y: size.height / 2 + 1.2, width: width, height: barHeight),
                fraction: session / 100, color: base)
            bar(NSRect(x: x, y: size.height / 2 - barHeight - 1.2, width: width, height: barHeight),
                fraction: week / 100, color: base.withAlphaComponent(tint == nil ? 0.65 : 0.8))
            return true
        }
        image.isTemplate = (tint == nil)
        return image
    }

    // MARK: - Батарейка (остаток сессии) с полоской недели

    static func battery(session: Double, week: Double, tint: NSColor?) -> NSImage {
        let size = NSSize(width: 24, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let base = tint ?? .black
            let body = NSRect(x: 0.9, y: size.height / 2 - 2.4, width: 19, height: 9.6)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
            outline.lineWidth = 1.5
            base.withAlphaComponent(0.75).setStroke()
            outline.stroke()

            // Контакт справа
            base.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 2, width: 2, height: 4),
                         xRadius: 1, yRadius: 1).fill()

            // Заливка — остаток сессии
            let remaining = max(0, min(1, 1 - session / 100))
            let inner = body.insetBy(dx: 2.2, dy: 2.2)
            if remaining > 0.01 {
                base.setFill()
                NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                                 width: inner.width * remaining, height: inner.height),
                             xRadius: 1.2, yRadius: 1.2).fill()
            }

            // Недельная квота — тонкая полоса под батарейкой
            bar(NSRect(x: 0.9, y: body.minY - 4.7, width: body.width, height: 2.4),
                fraction: week / 100, color: base.withAlphaComponent(tint == nil ? 0.6 : 0.8))
            return true
        }
        image.isTemplate = (tint == nil)
        return image
    }

    // MARK: - Точки

    static func dots(session: Double, week: Double, tint: NSColor?) -> NSImage {
        let size = NSSize(width: 23, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let base = tint ?? .black
            func row(y: CGFloat, radius: CGFloat, percent: Double, alpha: CGFloat) {
                let filled = Int((percent / 100 * 5).rounded(.up))
                for index in 0..<5 {
                    let rect = NSRect(x: 1.2 + CGFloat(index) * (radius * 2 + 1.3) + (1.6 - radius),
                                      y: y, width: radius * 2, height: radius * 2)
                    base.withAlphaComponent(index < filled ? alpha : trackAlpha).setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
            }
            row(y: size.height / 2 + 0.8, radius: 1.6, percent: session, alpha: 1.0)
            row(y: size.height / 2 - 4.2, radius: 1.3, percent: week, alpha: 0.7)
            return true
        }
        image.isTemplate = (tint == nil)
        return image
    }

    // MARK: - Особые состояния

    static func exhausted(tint: NSColor) -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: outerRadius, startAngle: 0, endAngle: 360)
            ring.lineWidth = ringWidth
            tint.setStroke()
            ring.stroke()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: center.x - 1.1, y: center.y - 0.6, width: 2.2, height: 5),
                         xRadius: 1.1, yRadius: 1.1).fill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.1, y: center.y - 4, width: 2.2, height: 2.2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func offline() -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            for radius in [outerRadius, innerRadius] {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                path.lineWidth = ringWidth
                path.setLineDash([2, 2.8], count: 2, phase: 0)
                NSColor.black.withAlphaComponent(0.5).setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Примитивы

    private static func track(center: NSPoint, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        path.lineWidth = ringWidth
        color.withAlphaComponent(trackAlpha).setStroke()
        path.stroke()
    }

    private static func arc(center: NSPoint, radius: CGFloat, fraction: Double, color: NSColor) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0.001 else { return }
        let path = NSBezierPath()
        if clamped >= 0.999 {
            path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        } else {
            path.appendArc(withCenter: center, radius: radius,
                           startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
        }
        path.lineWidth = ringWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func bar(_ rect: NSRect, fraction: Double, color: NSColor) {
        let radius = rect.height / 2
        color.withAlphaComponent(trackAlpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let clamped = max(0, min(1, fraction))
        guard clamped > 0.001 else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY,
                                         width: max(rect.height, rect.width * clamped), height: rect.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
