import AppKit
import SwiftUI

/// Отрисовка интерфейса в PNG без скриншотов экрана: `ClaudeUsage --render <каталог>`.
/// Помогает проверять вёрстку панели и настроек в обеих темах.
@MainActor
enum PreviewRenderer {
    static func renderAll(into directory: String) {
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        UsageStore.shared.loadPreviewSnapshot()

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            capture(PopoverView(openSettings: {})
                        .background(Color(nsColor: .windowBackgroundColor)),
                    size: NSSize(width: 316, height: 560),
                    appearance: appearance, to: base.appendingPathComponent("popover-\(name).png"))
            capture(SettingsView(), size: NSSize(width: 540, height: 640),
                    appearance: appearance, to: base.appendingPathComponent("settings-\(name).png"))
        }
    }

    /// Кладём вид в невидимое окно: AppKit-элементы (Form, Picker, Toggle)
    /// без окна не отрисовываются.
    private static func capture<V: View>(_ view: V, size: NSSize,
                                         appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSHostingView(rootView: AnyView(view))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.orderOut(nil)
    }
}
