import AppKit
import Foundation

// The test entrypoint substitutes only the App Group path in a temporary copy
// of SharedConfiguration.swift; all selection, persistence and catalog logic
// is compiled from the production implementation.

@main
struct ApplicationResolutionTests {
    @MainActor
    static func main() throws {
        let root = SharedConfiguration.containerURL!
        let manager = FileManager.default
        let identifier = "com.example.ApplicationResolution"
        var passed = 0

        func check(_ condition: Bool, _ label: String) throws {
            guard condition else {
                throw NSError(domain: "ApplicationResolutionTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: label])
            }
            passed += 1
            print("PASS: \(label)")
        }

        func fixture(_ name: String, identifier: String, installationID: String? = nil) throws -> AppRecord {
            let url = root.appendingPathComponent("\(name).app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try manager.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": identifier, "CFBundleDisplayName": name,
                         "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return AppRecord(bundleIdentifier: identifier, name: name,
                             bundlePath: url.path, iconFilename: "Icons/test.png",
                             installationIdentifier: installationID)
        }

        let stable = try fixture("Application 2026", identifier: identifier)
        let beta = try fixture("Application Beta", identifier: identifier, installationID: "install.test-beta")
        let other = try fixture("Other Application", identifier: "com.example.Other")
        let moved = AppRecord(bundleIdentifier: identifier, name: stable.name,
                              bundlePath: root.appendingPathComponent("Missing.app").path,
                              iconFilename: stable.iconFilename)
        var fallbacks = 0
        let chosen = AppCatalog.applicationURL(for: identifier, in: [stable]) {
            fallbacks += 1
            return beta.bundleURL
        }
        try check(chosen == stable.bundleURL && fallbacks == 0,
                  "The displayed installation wins over a Beta with the same identifier")
        try check(AppCatalog.applicationURL(for: beta.id, in: [stable, beta]) { stable.bundleURL } == beta.bundleURL,
                  "An explicitly cataloged Beta is respected")
        try check(AppCatalog.applicationURL(for: identifier, in: [moved]) { stable.bundleURL } == stable.bundleURL,
                  "A moved app with the same name and identifier is recovered")
        try check(AppCatalog.applicationURL(for: identifier, in: [moved]) { beta.bundleURL } == nil,
                  "An unavailable stable edition is not replaced by a Beta")
        try check(AppCatalog.applicationURL(for: identifier, in: [moved]) { other.bundleURL } == nil,
                  "A fallback with the wrong identifier is rejected")
        try check(AppCatalog.applicationURL(for: identifier, in: [moved]) { nil } == nil,
                  "An unavailable app returns no launch target")
        let replaced = AppRecord(bundleIdentifier: identifier, name: stable.name,
                                 bundlePath: other.bundlePath, iconFilename: stable.iconFilename)
        try check(AppCatalog.applicationURL(for: identifier, in: [replaced]) { nil } == nil,
                  "A different app at the cached path is rejected")
        try check(AppCatalog.applicationURL(for: identifier, in: []) { beta.bundleURL } == nil,
                  "An app absent from the catalog is not guessed from its identifier")

        let directory = AppCatalog.containerURL!
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([stable]).write(to: AppCatalog.manifestURL!, options: .atomic)
        try AppCatalog.refresh(in: [root.path])
        let fixtureRecords = try AppCatalog.read()
        let stableRecord = fixtureRecords.first { $0.bundlePath == stable.bundlePath }!
        let betaRecord = fixtureRecords.first { $0.bundlePath == beta.bundlePath }!
        try check(stableRecord.id == identifier && stableRecord.id != betaRecord.id,
                  "Duplicate bundle identifiers become distinct records without changing the legacy identity")
        try check(stableRecord.iconFilename != betaRecord.iconFilename,
                  "Each installation has an independent native icon cache")
        try check(Set(fixtureRecords.map(\.id)).count == fixtureRecords.count,
                  "Widget and library dictionary keys are unique")
        try AppCatalog.refresh(in: [root.path])
        try check(try AppCatalog.read() == fixtureRecords,
                  "Installation identities remain stable after another library refresh")
        try check(AppCatalog.applicationURL(for: betaRecord.id, in: fixtureRecords) { stable.bundleURL } == beta.bundleURL,
                  "The additional installation resolves its own bundle path")
        for record in [stableRecord, betaRecord] {
            let route = LaunchRoute.url(bundleIdentifier: record.id)
            guard case .application(let decodedID) = LaunchRoute.destination(from: route) else {
                throw NSError(domain: "Routes", code: 1)
            }
            try check(decodedID == record.id, "The widget route preserves the identity of \(record.name)")
        }
        var legacyItem = LauncherItem.application(identifier)
        legacyItem.customIconFilename = "preserved.png"
        let original = LauncherConfiguration(version: 1, items: [legacyItem],
            gridSettings: .init(mode: .manual, manualColumnCount: 3),
            displaySettings: .init(showsNames: false, density: .spacious))
        try SharedConfiguration.write(original)
        let store = ConfigurationStore()
        try check(store.contains(stableRecord) && !store.contains(betaRecord),
                  "An existing selection marks only the stable installation as selected")
        store.addApplications([stableRecord, betaRecord])
        try check(store.items.count == 2 && store.contains(stableRecord) && store.contains(betaRecord),
                  "Both installations can be selected together without adding a duplicate")
        try check(store.items.first { $0.target == stableRecord.id }?.customIconFilename == "preserved.png"
                  && store.gridSettings == original.gridSettings && store.displaySettings == original.displaySettings,
                  "Adding a Beta preserves the existing custom icon and layout preferences")
        store.toggle(betaRecord)
        try check(store.items == [legacyItem] && store.contains(stableRecord),
                  "Removing Beta leaves the stable entry intact")
        store.addApplications([betaRecord])
        store.moveToTop(legacyItem)
        store.reload()
        try check(store.items.map(\.target) == [stableRecord.id, betaRecord.id],
                  "Both installations and their order survive persistence and reload")
        try check(try SharedConfiguration.read().items.count == 2,
                  "Two installations pass the existing shared configuration validation")

        let relocatedURL = root.appendingPathComponent("Relocated/Application Beta.app")
        try manager.createDirectory(at: relocatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: beta.bundleURL, to: relocatedURL)
        try AppCatalog.refresh(in: [root.path])
        try check(try AppCatalog.read().first { $0.bundlePath == relocatedURL.path }?.id == betaRecord.id,
                  "Moving an additional edition preserves its selection identity")
        try manager.removeItem(at: stable.bundleURL)
        try AppCatalog.refresh(in: [root.path])
        try check(try AppCatalog.read().allSatisfy { $0.id != stableRecord.id },
                  "Removing the stable edition does not transfer its selection to Beta")

        let photoshopURL = URL(fileURLWithPath: "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app")
        let photoshopBetaURL = URL(fileURLWithPath: "/Applications/Adobe Photoshop (Beta)/Adobe Photoshop (Beta).app")
        if manager.fileExists(atPath: photoshopURL.path), manager.fileExists(atPath: photoshopBetaURL.path) {
            let photoshop = AppRecord(bundleIdentifier: "com.adobe.Photoshop", name: "Adobe Photoshop 2026",
                                      bundlePath: photoshopURL.path, iconFilename: "Icons/com.adobe.Photoshop.png")
            let systemURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: photoshop.bundleIdentifier)
            print("LaunchServices currently selects: \(systemURL?.path ?? "unavailable")")
            try check(Bundle(url: photoshopURL)?.bundleIdentifier == Bundle(url: photoshopBetaURL)?.bundleIdentifier,
                      "Both real Photoshop installations share their identifier")
            try check(AppCatalog.applicationURL(for: photoshop.bundleIdentifier, in: [photoshop]) { systemURL } == photoshopURL,
                      "The real Photoshop 2026 bundle is chosen")
            try JSONEncoder().encode([photoshop]).write(to: AppCatalog.manifestURL!, options: .atomic)
            try check(try AppCatalog.applicationURL(for: photoshop.bundleIdentifier) == photoshopURL,
                      "The companion entrypoint resolves the cataloged Photoshop")
            try AppCatalog.refresh()
            let realRecords = try AppCatalog.read()
            try check(realRecords.first { $0.id == photoshop.id }?.bundlePath == photoshopURL.path,
                      "Refreshing the real library preserves Photoshop 2026 over Beta")
            let realBeta = realRecords.first { $0.bundlePath == photoshopBetaURL.path }
            try check(realBeta != nil && realBeta?.id != photoshop.id,
                      "The real Photoshop Beta is now discovered separately")
            try check(realBeta?.iconFilename != photoshop.iconFilename,
                      "The two real Photoshop icon caches are separate")
            try check(try AppCatalog.applicationURL(for: realBeta!.id) == photoshopBetaURL,
                      "The real Beta widget route selects Photoshop Beta")
        } else {
            print("SKIP: real Photoshop checks (both installations are required)")
        }
        print("\(passed) application resolution checks passed. No application was launched; live data was not changed.")
    }
}
