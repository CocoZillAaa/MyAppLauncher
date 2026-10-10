import AppKit
import Combine
import Sparkle
import SwiftUI

@objc(LauncherWidgetMaintenance)
protocol LauncherWidgetMaintenance: NSObjectProtocol {
    @objc(prepareWidgetForUpdateWithReply:)
    func prepareWidgetForUpdate(reply: @escaping (String?) -> Void)
    @objc(registerInstalledWidgetWithReply:)
    func registerInstalledWidget(reply: @escaping (String?) -> Void)
}

@MainActor
final class LauncherUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = LauncherUpdates()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var statusMessage: String?
    private var observation: NSKeyValueObservation?
    private var controller: SPUStandardUpdaterController!
    private var maintenanceConnections: [UUID: NSXPCConnection] = [:]
    private var maintenanceReplies: [UUID: (String?) -> Void] = [:]
    private var started = false
    private var maintenanceFailed = false

    var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Version \(version) · build \(build)"
    }

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheckForUpdates = value }
        }
    }

    func start() {
        guard !started else { return }
        do {
            try controller.updater.start()
            // Detection may be automatic; download/installation always requires the user's choice.
            controller.updater.automaticallyDownloadsUpdates = false
            controller.updater.sendsSystemProfile = false
            automaticallyChecks = controller.updater.automaticallyChecksForUpdates
            started = true
        } catch {
            statusMessage = "La recherche de mises à jour est indisponible."
            SharedConfiguration.logger.error("Updater setup failed: \(String(reflecting: error), privacy: .private)")
        }
    }

    func checkForUpdates() {
        guard started, controller.updater.canCheckForUpdates else { return }
        statusMessage = nil
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func dismissStatus() { statusMessage = nil }

    func registerWidgetAfterVersionChange() async {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              UserDefaults.standard.string(forKey: "LastRegisteredWidgetBuild") != build else { return }
        let error = await withCheckedContinuation { continuation in
            callMaintenance(register: true) { error in continuation.resume(returning: error) }
        }
        if let error {
            statusMessage = "L’actualisation du widget n’a pas abouti. Fermez puis rouvrez le compagnon pour réessayer."
            SharedConfiguration.logger.error("Widget registration failed: \(error, privacy: .private)")
        } else {
            UserDefaults.standard.set(build, forKey: "LastRegisteredWidgetBuild")
            SharedConfiguration.logger.notice("Installed widget registered: build=\(build, privacy: .public)")
        }
    }

    private func callMaintenance(register: Bool, completion: @escaping (String?) -> Void) {
        let identifier = UUID()
        let connection = NSXPCConnection(serviceName: "com.openai.MyAppLauncher.WidgetMaintenance")
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"com.openai.MyAppLauncher.WidgetMaintenance\" and certificate leaf[subject.OU] = \"96H6RP27K3\"")
        connection.remoteObjectInterface = NSXPCInterface(with: LauncherWidgetMaintenance.self)
        maintenanceConnections[identifier] = connection
        maintenanceReplies[identifier] = completion
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.finishMaintenance(identifier, error: "Service interrompu.") }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.finishMaintenance(identifier, error: "Service indisponible.") }
        }
        connection.activate()
        guard let service = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.finishMaintenance(identifier, error: message) }
        }) as? LauncherWidgetMaintenance else {
            finishMaintenance(identifier, error: "Service indisponible.")
            return
        }
        let reply: (String?) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in self?.finishMaintenance(identifier, error: error) }
        }
        if register { service.registerInstalledWidget(reply: reply) }
        else { service.prepareWidgetForUpdate(reply: reply) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            self?.finishMaintenance(identifier, error: "Le service n’a pas répondu dans le délai prévu.")
        }
    }

    private func finishMaintenance(_ identifier: UUID, error: String?) {
        guard let completion = maintenanceReplies.removeValue(forKey: identifier) else { return }
        maintenanceConnections.removeValue(forKey: identifier)?.invalidate()
        completion(error)
    }

    // Block updates from other repositories and unencrypted or credential-bearing URLs.
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let url = updateItem.fileURL, url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil,
              url.path.hasPrefix("/CocoZillAaa/MyAppLauncher/releases/download/"),
              url.pathExtension == "zip" else {
            throw NSError(domain: "MyAppLauncher.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cette mise à jour ne provient pas de la source autorisée."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle invokes this only after the user has chosen installation.
        callMaintenance(register: false) { [weak self] error in
            if let error {
                // Sparkle 2.10 checks updaterShouldRelaunchApplication again when
                // the continuation resumes. Reject it to abort this install cycle.
                self?.maintenanceFailed = true
                installHandler()
                self?.statusMessage = "Installation suspendue : le widget n’a pas pu être fermé. Fermez puis rouvrez le compagnon pour réessayer."
                SharedConfiguration.logger.error("Update preparation failed: \(error, privacy: .private)")
                let alert = NSAlert()
                alert.messageText = "Installation suspendue"
                alert.informativeText = "Le widget n’a pas pu être fermé. L’installation n’a pas été poursuivie. Fermez puis rouvrez My App Launcher pour réessayer."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } else {
                SharedConfiguration.logger.notice("Widget stopped before confirmed update")
                installHandler()
            }
        }
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { !maintenanceFailed }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        maintenanceFailed = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        SharedConfiguration.logger.error("Update cycle failed: \(String(reflecting: error), privacy: .private)")
    }
}

struct LauncherUpdateSettings: View {
    @ObservedObject var updates: LauncherUpdates
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mises à jour").font(.headline)
            Text(updates.versionLabel).foregroundStyle(.secondary)
            Button("Rechercher une mise à jour…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
            Toggle("Rechercher automatiquement", isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.setAutomaticallyChecks($0) }
            ))
            Text("La recherche automatique fonctionne lorsque le compagnon est ouvert. L’installation reste soumise à votre confirmation.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = updates.statusMessage {
                HStack(alignment: .top) {
                    Text(message).font(.caption)
                    Button { updates.dismissStatus() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Masquer le message de mise à jour")
                }
            }
        }
        .padding(18)
        .frame(width: 330)
    }
}
