import AppKit
import SwiftUI

@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // без иконки в Dock
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--keychain-check") {
                TokenStore.migrateFromKeychain()
                UsageAPI.diagnose()
                NSApp.terminate(nil)
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--render"),
               CommandLine.arguments.count > index + 1 {
                TokenStore.migrateFromKeychain()
            L10n.shared.resolve(Preferences.shared.language)
                Fmt.localeDidChange()
                PreviewRenderer.renderAll(into: CommandLine.arguments[index + 1])
                NSApp.terminate(nil)
                return
            }
            TokenStore.migrateFromKeychain()
            L10n.shared.resolve(Preferences.shared.language)
            Fmt.localeDidChange()
            controller = StatusItemController()
            Notifier.requestAuthorizationIfNeeded()
            UsageStore.shared.start()
        }
    }
}
