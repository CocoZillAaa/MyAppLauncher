import AppKit
import SwiftUI
import WidgetKit

@main
struct MyAppLauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherDelegate.self) private var delegate
    @ObservedObject private var updates = LauncherUpdates.shared
    var body: some Scene {
        MenuBarExtra("My App Launcher", systemImage: "square.grid.2x2") {
            Button("Configurer…") { delegate.showCompanion() }
            Button("Rechercher une mise à jour…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
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
            await LauncherUpdates.shared.registerWidgetAfterVersionChange()
            LauncherUpdates.shared.start()
            do {
                var applications = AppCatalog.load()
                if applications.isEmpty || applications.contains(where: { $0.installationIdentifier == nil }) {
                    try await AppCatalog.refresh()
                    applications = AppCatalog.load()
                }
                try SharedConfiguration.seedIfMissing(applications: applications)
                let saved = try SharedConfiguration.read()
                SharedConfiguration.logger.notice("Companion read shared configuration: \(saved.items.count) items")
                WidgetCenter.shared.reloadTimelines(ofKind: "MyAppLauncherWidget")
            } catch {
                SharedConfiguration.logger.error("Companion configuration setup failed: \(String(reflecting: error), privacy: .private)")
            }
            await reloadWidgetsAfterVersionChange()
        }
        AppCatalog.logger.notice("Companion ready; no automatic window")
    }

    private func reloadWidgetsAfterVersionChange() async {
        // This marker records requests, not an acknowledgement from WidgetKit.
        // Keeping it outside the App Group leaves the selection untouched.
        let markerKey = "LastWidgetReloadRequestedBuild"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              UserDefaults.standard.string(forKey: markerKey) != build else { return }

        var lastRequestWasPrepared = false
        // Two bounded follow-ups give macOS time to discover the new extension.
        // Sleep suspends this task and does not block the companion's UI.
        for delay in [8.0, 22.0] {
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            do {
                let configuration = try SharedConfiguration.read()
                let selectedApplications = configuration.items.filter { $0.kind == .application }
                let applications = selectedApplications.isEmpty ? [] : try AppCatalog.read()
                let selectedIDs = Set(selectedApplications.map(\.target))
                let missingIcons = applications.filter { selectedIDs.contains($0.id) }.filter { app in
                    guard let url = app.iconURL else { return true }
                    return !FileManager.default.fileExists(atPath: url.path)
                }.count
                WidgetCenter.shared.reloadTimelines(ofKind: "MyAppLauncherWidget")
                lastRequestWasPrepared = missingIcons == 0
                SharedConfiguration.logger.notice("Upgrade widget reload requested: build=\(build, privacy: .public), items=\(configuration.items.count), missingIcons=\(missingIcons)")
            } catch {
                lastRequestWasPrepared = false
                SharedConfiguration.logger.error("Upgrade widget reload preparation failed: \(String(reflecting: error), privacy: .private)")
            }
        }
        if lastRequestWasPrepared {
            UserDefaults.standard.set(build, forKey: markerKey)
        }
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
                            AppCatalog.logger.error("Application unavailable: \(identifier, privacy: .private)")
                            return
                        }
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        // Keep this exact installation: macOS otherwise reuses
                        // an open edition at another URL with the same bundle ID.
                        configuration.allowsRunningApplicationSubstitution = false
                        let launched = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
                        AppCatalog.logger.notice("Launch succeeded: \(identifier, privacy: .private), path=\(target.path, privacy: .private), actualPath=\(launched.bundleURL?.path ?? "unknown", privacy: .private), pid=\(launched.processIdentifier), companionWindows=\(self.companionWindow?.isVisible == true ? 1 : 0)")
                    } catch {
                        AppCatalog.logger.error("Launch failed: \(String(reflecting: error), privacy: .private)")
                    }
                }
            case .website(let website):
                let opened = NSWorkspace.shared.open(website)
                AppCatalog.logger.notice("Website open \(opened ? "succeeded" : "failed", privacy: .public): \(website.absoluteString, privacy: .private), companionWindows=\(self.companionWindow?.isVisible == true ? 1 : 0)")
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
            window.contentView = NSHostingView(rootView: CompanionView(updates: .shared))
            window.isReleasedWhenClosed = false
            window.center()
            companionWindow = window
        }
        companionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppCatalog.logger.notice("Companion window opened explicitly")
    }
}
