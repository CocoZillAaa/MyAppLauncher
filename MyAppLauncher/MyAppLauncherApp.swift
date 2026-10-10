import AppKit
import SwiftUI
import WidgetKit

@main
struct MyAppLauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("My App Launcher", systemImage: "square.grid.2x2") {
            Button("Configurer…") { delegate.showCompanion() }
            Divider()
            Button("Quitter My App Launcher") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var companionWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement keeps cold URL launches out of the Dock.
        SharedConfiguration.logContainerAvailability(component: "Companion")
        Task { @MainActor in
            do {
                var applications = AppCatalog.load()
                if applications.isEmpty || applications.contains(where: { $0.installationIdentifier == nil }) {
                    try AppCatalog.refresh()
                    applications = AppCatalog.load()
                }
                try SharedConfiguration.seedIfMissing(applications: applications)
                let saved = try SharedConfiguration.read()
                SharedConfiguration.logger.notice("Companion read shared configuration: \(saved.items.count) items")
                WidgetCenter.shared.reloadTimelines(ofKind: "MyAppLauncherWidget")
            } catch {
                SharedConfiguration.logger.error("Companion configuration setup failed: \(String(reflecting: error), privacy: .public)")
            }
        }
        AppCatalog.logger.notice("Companion ready; no automatic window")
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showCompanion()
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCompanion()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let destination = LaunchRoute.destination(from: url) else { continue }
            switch destination {
            case .configuration:
                showCompanion()
            case .application(let identifier):
                Task { @MainActor in
                    do {
                        guard let target = try AppCatalog.applicationURL(for: identifier),
                              Bundle(url: target)?.bundleIdentifier != Bundle.main.bundleIdentifier else {
                            AppCatalog.logger.error("Application unavailable: \(identifier, privacy: .public)")
                            return
                        }
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        // Keep this exact installation: macOS otherwise reuses
                        // an open edition at another URL with the same bundle ID.
                        configuration.allowsRunningApplicationSubstitution = false
                        let launched = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
                        AppCatalog.logger.notice("Launch succeeded: \(identifier, privacy: .public), path=\(target.path, privacy: .public), actualPath=\(launched.bundleURL?.path ?? "unknown", privacy: .public), pid=\(launched.processIdentifier), companionWindows=\(self.companionWindow?.isVisible == true ? 1 : 0)")
                    } catch {
                        AppCatalog.logger.error("Launch failed: \(String(reflecting: error), privacy: .public)")
                    }
                }
            case .website(let website):
                let opened = NSWorkspace.shared.open(website)
                AppCatalog.logger.notice("Website open \(opened ? "succeeded" : "failed", privacy: .public): \(website.absoluteString, privacy: .public), companionWindows=\(self.companionWindow?.isVisible == true ? 1 : 0)")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === companionWindow else { return }
        AppCatalog.logger.notice("Companion window closed; quitting application")
        NSApp.terminate(nil)
    }

    func showCompanion() {
        if companionWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "My App Launcher"
            window.delegate = self
            window.contentView = NSHostingView(rootView: CompanionView())
            window.isReleasedWhenClosed = false
            window.center()
            companionWindow = window
        }
        companionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppCatalog.logger.notice("Companion window opened explicitly")
    }
}
