import AppKit
import CryptoKit
import Darwin
import Foundation
import OSLog

struct AppRecord: Codable, Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let bundlePath: String
    let iconFilename: String
    let isBackgroundComponent: Bool
    let installationIdentifier: String?
    let iconSourceFingerprint: String?

    // Existing records retain their bundle ID; additional installations get an
    // independent catalog identity without changing existing selected items.
    var id: String { installationIdentifier ?? bundleIdentifier }
    var bundleURL: URL { URL(fileURLWithPath: bundlePath) }
    var iconURL: URL? { AppCatalog.iconURL(for: iconFilename) }
    var isAuxiliary: Bool {
        isBackgroundComponent || AppCatalog.looksAuxiliary(name: name, bundleIdentifier: bundleIdentifier)
    }

    init(bundleIdentifier: String, name: String, bundlePath: String, iconFilename: String, isBackgroundComponent: Bool = false, installationIdentifier: String? = nil, iconSourceFingerprint: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        self.iconFilename = iconFilename
        self.isBackgroundComponent = isBackgroundComponent
        self.installationIdentifier = installationIdentifier
        self.iconSourceFingerprint = iconSourceFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, bundlePath, iconFilename, isBackgroundComponent, installationIdentifier, iconSourceFingerprint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        name = try values.decode(String.self, forKey: .name)
        bundlePath = try values.decode(String.self, forKey: .bundlePath)
        iconFilename = try values.decode(String.self, forKey: .iconFilename)
        isBackgroundComponent = try values.decodeIfPresent(Bool.self, forKey: .isBackgroundComponent) ?? false
        installationIdentifier = try values.decodeIfPresent(String.self, forKey: .installationIdentifier)
        iconSourceFingerprint = try values.decodeIfPresent(String.self, forKey: .iconSourceFingerprint)
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
        guard let shared = SharedConfiguration.containerURL else { return nil }
        return BoundedLocalFile.confinedURL(in: shared, relativePath: directoryName)
    }

    static var manifestURL: URL? {
        containerURL?.appendingPathComponent(manifestName)
    }

    static func read() throws -> [AppRecord] {
        guard let url = manifestURL else { throw CatalogError.containerUnavailable }
        let data = try BoundedLocalFile.read(url, maximumBytes: 8 * 1024 * 1024)
        let records = try JSONDecoder().decode([AppRecord].self, from: data)
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy({
                  LaunchRoute.isValidBundleIdentifier($0.id) &&
                  LaunchRoute.isValidBundleIdentifier($0.bundleIdentifier) &&
                  $0.bundlePath.hasPrefix("/") && $0.bundleURL.pathExtension.lowercased() == "app" &&
                  isValidIconPath($0.iconFilename) &&
                  ($0.iconSourceFingerprint.map { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } ?? true)
              }) else { throw CatalogError.invalidCatalog }
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isValidIconPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == Substring(iconDirectory) &&
            IconAssetStore.isValidFilename(String(parts[1]))
    }

    static func iconURL(for path: String) -> URL? {
        guard isValidIconPath(path), let container = containerURL else { return nil }
        return BoundedLocalFile.confinedURL(in: container, relativePath: path)
    }

    static func load() -> [AppRecord] {
        do { return try read() }
        catch {
            logger.error("Catalog read failed: \(String(reflecting: error), privacy: .private)")
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

    @discardableResult
    static func refresh(in roots: [String] = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]) async throws -> Int {
        let task = Task.detached(priority: .userInitiated) {
            try await refreshCatalog(in: roots)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func refreshCatalog(in roots: [String]) async throws -> Int {
        guard let container = containerURL else { throw CatalogError.containerUnavailable }
        let manager = FileManager.default
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        // A companion and a widget are separate processes. Hold a scoped file
        // lock until all icons and the manifest have been committed and verified.
        let descriptor = try await acquireRefreshLock(in: container)
        defer { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
        logger.notice("Refreshing local catalog in background")
        guard let iconsURL = BoundedLocalFile.confinedURL(in: container, relativePath: iconDirectory) else {
            throw CatalogError.containerUnavailable
        }
        try manager.createDirectory(at: iconsURL, withIntermediateDirectories: true)
        let bundleURLs = discoverApplications(in: roots, fileManager: manager)
        let previousRecords = (try? read()) ?? []
        let byPath = Dictionary(previousRecords.map { ($0.bundlePath, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(uniqueKeysWithValues: previousRecords.map { ($0.id, $0) })
        let previousPaths = Set(previousRecords.map(\.bundlePath))
        let discoveredPaths = Set(bundleURLs.map(\.path))
        let preferredURLs = bundleURLs.filter { previousPaths.contains($0.path) }
            + bundleURLs.filter { !previousPaths.contains($0.path) }
        var seen = Set<String>()
        var records: [AppRecord] = []
        var generatedIcons = 0
        let day = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        let dayStamp = "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        for url in preferredURLs {
            try Task.checkCancellation()
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  LaunchRoute.isValidBundleIdentifier(identifier) else { continue }
            let name = applicationName(bundle: bundle, url: url)
            let previous = byPath[url.path].flatMap { $0.bundleIdentifier == identifier ? $0 : nil }
            let relocated = previousRecords.filter {
                $0.bundleIdentifier == identifier && $0.name == name && !discoveredPaths.contains($0.bundlePath)
            }
            let legacy = byID[identifier]
            let pathHash = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let separateIdentifier = "install.\(pathHash)"
            var installationID = previous?.id
                ?? (relocated.count == 1 ? relocated[0].id : nil)
                ?? (legacy == nil || legacy?.name == name ? identifier : separateIdentifier)
            if seen.contains(installationID) { installationID = separateIdentifier }
            guard seen.insert(installationID).inserted else { continue }
            let filename = "\(installationID.replacingOccurrences(of: "/", with: "_")).png"
            let iconURL = iconsURL.appendingPathComponent(filename)
            let fingerprint = iconFingerprint(bundle: bundle, url: url, dayStamp: dayStamp)
            let canReuseIcon = fingerprint != nil && fingerprint == previous?.iconSourceFingerprint
                && previous?.iconFilename == "\(iconDirectory)/\(filename)"
                && IconAssetStore.loadCachedCGImage(from: iconURL) != nil
            if !canReuseIcon {
                // Keep AppKit drawing confined to short main-actor operations.
                // Scanning, metadata, disk IO and publication run in this task.
                guard let png = await nativeIconPNG(at: url) else { continue }
                try png.write(to: iconURL, options: .atomic)
                generatedIcons += 1
            }
            let backgroundComponent = (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false)
                || (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool ?? false)
            records.append(AppRecord(bundleIdentifier: identifier, name: name, bundlePath: url.path,
                iconFilename: "\(iconDirectory)/\(filename)", isBackgroundComponent: backgroundComponent,
                installationIdentifier: installationID, iconSourceFingerprint: fingerprint))
        }
        records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try Task.checkCancellation()
        if records != previousRecords {
            let data = try JSONEncoder().encode(records)
            guard data.count <= 8 * 1024 * 1024 else { throw BoundedLocalFile.ReadError.tooLarge }
            try data.write(to: container.appendingPathComponent(manifestName), options: .atomic)
        }
        let saved = try read()
        guard saved == records else { throw CatalogError.verificationFailed }
        logger.notice("Catalog verified: \(saved.count) applications, \(generatedIcons) regenerated icons")
        return saved.count
    }

    private static func acquireRefreshLock(in container: URL) async throws -> Int32 {
        guard let url = BoundedLocalFile.confinedURL(in: container, relativePath: "Refresh.lock") else {
            throw BoundedLocalFile.ReadError.invalidFile
        }
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw CatalogError.refreshUnavailable }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            _ = Darwin.close(descriptor)
            throw BoundedLocalFile.ReadError.invalidFile
        }
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            while true {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw CatalogError.refreshUnavailable }
                guard clock.now < deadline else { throw CatalogError.refreshUnavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func iconFingerprint(bundle: Bundle, url: URL, dayStamp: String) -> String? {
        guard let identity = BoundedLocalFile.identity(of: url, regularFileOnly: false) else { return nil }
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        var paths = [url.appendingPathComponent("Contents/Info.plist"), resources,
                     resources.appendingPathComponent("Assets.car")]
        if let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           !file.isEmpty, URL(fileURLWithPath: file).lastPathComponent == file {
            paths.append(resources.appendingPathComponent(file))
            if URL(fileURLWithPath: file).pathExtension.isEmpty {
                paths.append(resources.appendingPathComponent(file + ".icns"))
            }
        }
        // Refresh daily as well, for system-generated icons that vary by date.
        let metadata = [identity, dayStamp] + paths.map {
            $0.path + ":" + (BoundedLocalFile.identity(of: $0, regularFileOnly: false) ?? "missing")
        }
        return SHA256.hash(data: Data(metadata.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private static func nativeIconPNG(at url: URL) -> Data? {
        autoreleasepool {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return bitmap.representation(using: .png, properties: [:])
        }
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
                    logger.error("Application scan skipped an inaccessible path: \(url.path, privacy: .private), \(String(reflecting: error), privacy: .private)")
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
        case containerUnavailable, verificationFailed, invalidCatalog, refreshUnavailable
        var errorDescription: String? {
            switch self {
            case .containerUnavailable: "Le dossier de cache des applications est inaccessible."
            case .verificationFailed: "Le catalogue enregistré n’a pas pu être vérifié."
            case .refreshUnavailable: "Une actualisation de la bibliothèque est déjà en cours ou inaccessible. Réessayez."
            case .invalidCatalog: "Le catalogue contient une entrée invalide ou en double. Actualisez la bibliothèque."
            }
        }
    }
}
