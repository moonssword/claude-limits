#!/usr/bin/env swift
// Генерирует иконку приложения (кольца сессии и недели) в PNG заданного размера.
import AppKit

let args = CommandLine.arguments
let size = args.count > 1 ? Double(args[1]) ?? 1024 : 1024
let out = args.count > 2 ? args[2] : "icon.png"

let side = CGFloat(size)
let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    let inset = side * 0.06
    let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    ])!
    let shape = NSBezierPath(roundedRect: body, xRadius: side * 0.22, yRadius: side * 0.22)
    gradient.draw(in: shape, angle: -90)

    let center = NSPoint(x: rect.midX, y: rect.midY)
    let lineWidth = side * 0.075
    func ring(_ radius: CGFloat, _ fraction: Double, _ color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.16).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
    ring(side * 0.27, 0.61, NSColor(srgbRed: 0.94, green: 0.68, blue: 0.31, alpha: 1))
    ring(side * 0.155, 0.41, NSColor(srgbRed: 0.55, green: 0.82, blue: 0.62, alpha: 1))
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
