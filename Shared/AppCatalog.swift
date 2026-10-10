import AppKit
import CryptoKit
import Foundation
import OSLog

struct AppRecord: Codable, Identifiable, Hashable {
    let bundleIdentifier: String
    let name: String
    let bundlePath: String
    let iconFilename: String
    let isBackgroundComponent: Bool
    let installationIdentifier: String?

    // Existing records retain their bundle ID; additional installations get an
    // independent catalog identity without changing existing selected items.
    var id: String { installationIdentifier ?? bundleIdentifier }
    var bundleURL: URL { URL(fileURLWithPath: bundlePath) }
    var iconURL: URL? { AppCatalog.containerURL?.appendingPathComponent(iconFilename) }
    var isAuxiliary: Bool {
        isBackgroundComponent || AppCatalog.looksAuxiliary(name: name, bundleIdentifier: bundleIdentifier)
    }

    init(bundleIdentifier: String, name: String, bundlePath: String, iconFilename: String, isBackgroundComponent: Bool = false, installationIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        self.iconFilename = iconFilename
        self.isBackgroundComponent = isBackgroundComponent
        self.installationIdentifier = installationIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, bundlePath, iconFilename, isBackgroundComponent, installationIdentifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        name = try values.decode(String.self, forKey: .name)
        bundlePath = try values.decode(String.self, forKey: .bundlePath)
        iconFilename = try values.decode(String.self, forKey: .iconFilename)
        isBackgroundComponent = try values.decodeIfPresent(Bool.self, forKey: .isBackgroundComponent) ?? false
        installationIdentifier = try values.decodeIfPresent(String.self, forKey: .installationIdentifier)
    }
}

enum AppCatalog {
    static let logger = Logger(subsystem: "com.openai.MyAppLauncher", category: "Catalog")
    static let directoryName = "ApplicationCatalog"
    static let manifestName = "applications.json"
    static let iconDirectory = "Icons"

    static func looksAuxiliary(name: String, bundleIdentifier: String) -> Bool {
        let value = "\(name) \(bundleIdentifier)".lowercased()
        let markers = [
            "render engine", "content synchronizer", "diagnostics", "crash reporter",
            "uninstaller", "updater", "update helper", "install helper",
            "background helper", " helper.app", ".helper", ".agent"
        ]
        return markers.contains { value.contains($0) }
    }

    static var containerURL: URL? {
        SharedConfiguration.containerURL?.appendingPathComponent(directoryName, isDirectory: true)
    }

    static var manifestURL: URL? {
        containerURL?.appendingPathComponent(manifestName)
    }

    static func read() throws -> [AppRecord] {
        guard let url = manifestURL else { throw CatalogError.containerUnavailable }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AppRecord].self, from: data)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func load() -> [AppRecord] {
        do { return try read() }
        catch {
            logger.error("Catalog read failed: \(String(reflecting: error), privacy: .public)")
            return []
        }
    }

    @MainActor
    static func applicationURL(for identifier: String) throws -> URL? {
        // Read the same catalog that supplies the displayed name and icon.
        // LaunchServices may choose a different edition with the same bundle ID.
        let applications = try read()
        return applicationURL(for: identifier, in: applications) {
            guard let application = applications.first(where: { $0.id == identifier }) else { return nil }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier)
        }
    }

    static func applicationURL(
        for identifier: String,
        in applications: [AppRecord],
        fallbackURL: () -> URL?
    ) -> URL? {
        guard let application = applications.first(where: { $0.id == identifier }) else {
            return nil
        }
        if FileManager.default.fileExists(atPath: application.bundlePath),
           Bundle(url: application.bundleURL)?.bundleIdentifier == application.bundleIdentifier {
            return application.bundleURL
        }

        // Recover a moved application, but never substitute another edition
        // (for example Photoshop Beta) that happens to share its identifier.
        guard let candidate = fallbackURL(),
              FileManager.default.fileExists(atPath: candidate.path),
              let bundle = Bundle(url: candidate), bundle.bundleIdentifier == application.bundleIdentifier,
              applicationName(bundle: bundle, url: candidate) == application.name else {
            return nil
        }
        return candidate
    }

    private static func applicationName(bundle: Bundle, url: URL) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    @MainActor
    @discardableResult
    static func refresh(in roots: [String] = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]) throws -> Int {
        guard let container = containerURL else { throw CatalogError.containerUnavailable }
        logger.notice("Refreshing local catalog")
        let manager = FileManager.default
        let iconsURL = container.appendingPathComponent(iconDirectory, isDirectory: true)
        try manager.createDirectory(at: iconsURL, withIntermediateDirectories: true)

        let bundleURLs = discoverApplications(in: roots, fileManager: manager)

        // Preserve the catalog's chosen installation when several applications
        // share an identifier. Directory enumeration order must not change it.
        let previousRecords = (try? read()) ?? []
        let previousPaths = Set(previousRecords.map(\.bundlePath))
        let discoveredPaths = Set(bundleURLs.map(\.path))
        let preferredURLs = bundleURLs.filter { previousPaths.contains($0.path) }
            + bundleURLs.filter { !previousPaths.contains($0.path) }

        var seen = Set<String>()
        var records: [AppRecord] = []
        for url in preferredURLs {
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier else { continue }
            let name = applicationName(bundle: bundle, url: url)
            let previous = previousRecords.first { $0.bundlePath == url.path && $0.bundleIdentifier == identifier }
            let relocated = previousRecords.filter {
                $0.bundleIdentifier == identifier && $0.name == name && !discoveredPaths.contains($0.bundlePath)
            }
            let legacy = previousRecords.first { $0.id == identifier }
            let pathHash = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let separateIdentifier = "install.\(pathHash)"
            var installationID = previous?.id
                ?? (relocated.count == 1 ? relocated[0].id : nil)
                ?? (legacy == nil || legacy?.name == name ? identifier : separateIdentifier)
            if seen.contains(installationID) { installationID = separateIdentifier }
            guard seen.insert(installationID).inserted else { continue }
            let filename = "\(installationID.replacingOccurrences(of: "/", with: "_")).png"
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256),
                from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: iconsURL.appendingPathComponent(filename), options: .atomic)
            let backgroundComponent = (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false)
                || (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool ?? false)
            records.append(AppRecord(
                bundleIdentifier: identifier,
                name: name,
                bundlePath: url.path,
                iconFilename: "\(iconDirectory)/\(filename)",
                isBackgroundComponent: backgroundComponent,
                installationIdentifier: installationID
            ))
        }
        records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let url = container.appendingPathComponent(manifestName)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
        let saved = try read()
        guard saved == records else { throw CatalogError.verificationFailed }
        logger.notice("Catalog saved and read back: \(saved.count) applications")
        return saved.count
    }

    private static func discoverApplications(in roots: [String], fileManager: FileManager) -> [URL] {
        var discovered: [URL] = []
        var seenPaths = Set<String>()
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]

        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    logger.error("Application scan skipped an inaccessible path: \(url.path, privacy: .public), \(String(reflecting: error), privacy: .public)")
                    return true
                }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }

                // An .app is a package. Record it once, then avoid scanning its
                // frameworks, helpers, plug-ins, and embedded applications.
                if (try? url.resourceValues(forKeys: Set(resourceKeys)).isDirectory) == true,
                   seenPaths.insert(url.standardizedFileURL.path).inserted {
                    discovered.append(url)
                }
                enumerator.skipDescendants()
            }
        }
        return discovered
    }

    enum CatalogError: LocalizedError {
        case containerUnavailable, verificationFailed
        var errorDescription: String? {
            switch self {
            case .containerUnavailable: "Le dossier de cache des applications est inaccessible."
            case .verificationFailed: "Le catalogue enregistré n’a pas pu être vérifié."
            }
        }
    }
}
