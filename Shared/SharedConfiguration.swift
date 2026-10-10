import AppKit
import ImageIO
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Read only regular files, with an allocation bound even if the file grows.
enum BoundedLocalFile {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ReadError.invalidFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        }
        return data
    }

    /// Cache paths must remain inside their directory, including symlink resolution.
    static func confinedURL(in directory: URL, relativePath: String) -> URL? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedCandidate = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    enum ReadError: LocalizedError {
        case invalidFile, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidFile: "Le fichier de données n’est pas un fichier ordinaire."
            case .tooLarge: "Le fichier de données dépasse la taille autorisée."
            }
        }
    }
}

enum SharedConfiguration {
    static let groupIdentifier = "96H6RP27K3.myapplauncher"
    static let logger = Logger(subsystem: "com.openai.MyAppLauncher", category: "SharedConfiguration")
    static let filename = "LauncherConfiguration.json"
    private static let maximumConfigurationBytes = 4 * 1024 * 1024

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    static var fileURL: URL? { containerURL?.appendingPathComponent(filename) }

    static func read() throws -> LauncherConfiguration {
        guard let fileURL else { throw ConfigurationError.containerUnavailable }
        let data = try BoundedLocalFile.read(fileURL, maximumBytes: maximumConfigurationBytes)
        let storedConfiguration = try JSONDecoder().decode(LauncherConfiguration.self, from: data)
        let configuration = migrateLegacyWebsiteIcons(in: storedConfiguration)
        try validate(configuration)
        if configuration != storedConfiguration {
            let migratedData = try JSONEncoder().encode(configuration)
            try migratedData.write(to: fileURL, options: .atomic)
            logger.notice("Migrated website icon overrides to the dedicated configuration field")
        }
        return configuration
    }

    static func write(_ configuration: LauncherConfiguration) throws {
        guard let fileURL else { throw ConfigurationError.containerUnavailable }
        try validate(configuration)
        let data = try JSONEncoder().encode(configuration)
        guard data.count <= maximumConfigurationBytes else { throw BoundedLocalFile.ReadError.tooLarge }
        try data.write(to: fileURL, options: .atomic)
        guard try read() == configuration else { throw ConfigurationError.verificationFailed }
        logger.notice("Shared configuration saved: \(configuration.items.count) items")
    }

    private static func validate(_ configuration: LauncherConfiguration) throws {
        guard configuration.version == LauncherConfiguration.currentVersion else {
            throw ConfigurationError.unsupportedVersion
        }
        guard Set(configuration.items.map(\.id)).count == configuration.items.count else {
            throw ConfigurationError.invalidItem
        }
        guard (1...WidgetGridSettings.maximumManualColumns).contains(configuration.gridSettings.manualColumnCount) else {
            throw ConfigurationError.invalidItem
        }
        for item in configuration.items {
            switch item.kind {
            case .application:
                guard item.id == "app:\(item.target)",
                      LaunchRoute.isValidBundleIdentifier(item.target),
                      item.websiteIconFilename == nil,
                      item.websiteCustomIconFilename == nil,
                      item.customIconFilename.map(IconAssetStore.isValidFilename) ?? true else {
                    throw ConfigurationError.invalidItem
                }
            case .website:
                guard item.id.hasPrefix("web:"), !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      LaunchRoute.validWebsiteURL(item.target) != nil,
                      item.customIconFilename == nil,
                      item.websiteCustomIconFilename.map(IconAssetStore.isValidFilename) ?? true,
                      item.websiteIconFilename.map(IconAssetStore.isValidFilename) ?? true else {
                    throw ConfigurationError.invalidItem
                }
            }
        }
    }

    private static func migrateLegacyWebsiteIcons(in configuration: LauncherConfiguration) -> LauncherConfiguration {
        var migrated = configuration
        for index in migrated.items.indices where migrated.items[index].kind == .website {
            guard let legacyFilename = migrated.items[index].customIconFilename else { continue }
            migrated.items[index].websiteCustomIconFilename = legacyFilename
            migrated.items[index].customIconFilename = nil
        }
        return migrated
    }

    static func seedIfMissing(applications: [AppRecord]) throws {
        guard let fileURL else { throw ConfigurationError.containerUnavailable }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let configuration = LauncherConfiguration(
            version: LauncherConfiguration.currentVersion,
            items: applications.map { .application($0.id) }
        )
        try write(configuration)
        let saved = try read()
        guard saved == configuration else { throw ConfigurationError.verificationFailed }
        logger.notice("Shared configuration seeded and verified: \(saved.items.count) applications")
    }

    static func logContainerAvailability(component: String) {
        if let containerURL {
            logger.notice("\(component, privacy: .public) app group available: \(containerURL.path, privacy: .private)")
        } else {
            logger.error("\(component, privacy: .public) app group unavailable")
        }
    }

    enum ConfigurationError: LocalizedError {
        case containerUnavailable, unsupportedVersion, verificationFailed, invalidItem

        var errorDescription: String? {
            switch self {
            case .containerUnavailable: "Le conteneur partagé est inaccessible."
            case .unsupportedVersion: "La version du catalogue partagé n’est pas prise en charge."
            case .verificationFailed: "Le catalogue partagé n’a pas pu être vérifié après écriture."
            case .invalidItem: "La configuration contient une entrée invalide ou en double."
            }
        }
    }
}

struct LauncherConfiguration: Codable, Equatable {
    static let currentVersion = 1
    let version: Int
    var items: [LauncherItem]
    var gridSettings: WidgetGridSettings
    var displaySettings: WidgetDisplaySettings

    init(
        version: Int,
        items: [LauncherItem],
        gridSettings: WidgetGridSettings = .init(),
        displaySettings: WidgetDisplaySettings = .init()
    ) {
        self.version = version
        self.items = items
        self.gridSettings = gridSettings
        self.displaySettings = displaySettings
    }

    private enum CodingKeys: String, CodingKey {
        case version, items, gridSettings, displaySettings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        items = try values.decode([LauncherItem].self, forKey: .items)
        gridSettings = try values.decodeIfPresent(WidgetGridSettings.self, forKey: .gridSettings) ?? .init()
        displaySettings = try values.decodeIfPresent(WidgetDisplaySettings.self, forKey: .displaySettings) ?? .init()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(items, forKey: .items)
        try values.encode(gridSettings, forKey: .gridSettings)
        try values.encode(displaySettings, forKey: .displaySettings)
    }
}

struct WidgetGridSettings: Codable, Equatable {
    enum Mode: String, Codable { case automatic, manual }

    static let maximumManualColumns = 8
    var mode: Mode = .automatic
    var manualColumnCount = 4

    private enum CodingKeys: String, CodingKey {
        case mode, manualColumnCount
    }

    init(mode: Mode = .automatic, manualColumnCount: Int = 4) {
        self.mode = mode
        self.manualColumnCount = manualColumnCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .automatic
        manualColumnCount = try values.decodeIfPresent(Int.self, forKey: .manualColumnCount) ?? 4
    }
}

struct WidgetDisplaySettings: Codable, Equatable {
    enum Density: String, Codable, CaseIterable {
        case compact
        case balanced
        case spacious

        var title: String {
            switch self {
            case .compact: "Compacte"
            case .balanced: "Équilibrée"
            case .spacious: "Aérée"
            }
        }
    }

    var showsNames = true
    var density: Density = .balanced

    private enum CodingKeys: String, CodingKey {
        case showsNames, density
    }

    init(showsNames: Bool = true, density: Density = .balanced) {
        self.showsNames = showsNames
        self.density = density
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsNames = try values.decodeIfPresent(Bool.self, forKey: .showsNames) ?? true
        density = try values.decodeIfPresent(Density.self, forKey: .density) ?? .balanced
    }
}

struct LauncherItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case application, website }

    let id: String
    let kind: Kind
    var title: String
    var target: String
    var customIconFilename: String? = nil
    var websiteIconFilename: String? = nil
    var websiteCustomIconFilename: String? = nil

    var personalIconFilename: String? {
        kind == .website ? websiteCustomIconFilename : customIconFilename
    }

    /// The target is a catalog installation ID (a bundle ID for legacy entries).
    static func application(_ installationIdentifier: String) -> LauncherItem {
        LauncherItem(id: "app:\(installationIdentifier)", kind: .application, title: "", target: installationIdentifier,
                     customIconFilename: nil, websiteIconFilename: nil, websiteCustomIconFilename: nil)
    }

    static func website(title: String, url: URL) -> LauncherItem {
        LauncherItem(id: "web:\(UUID().uuidString)", kind: .website, title: title, target: url.absoluteString,
                     customIconFilename: nil, websiteIconFilename: nil, websiteCustomIconFilename: nil)
    }
}

enum IconAssetStore {
    private static let directoryName = "LauncherIcons"
    private static let maximumSourceSize = 20 * 1024 * 1024
    private static let maximumCustomImageSize = 1 * 1024 * 1024
    private static let maximumCustomImageSide = 1024
    private static let outputSide = 256
    private static let maximumDownloadedImageSide = 8192
    private static let maximumCachedImageBytes = 1 * 1024 * 1024

    static func url(for filename: String?) -> URL? {
        guard let filename, isValidFilename(filename),
              let container = SharedConfiguration.containerURL else { return nil }
        return BoundedLocalFile.confinedURL(in: container, relativePath: "\(directoryName)/\(filename)")
    }

    static func isValidFilename(_ filename: String) -> Bool {
        filename.hasSuffix(".png") &&
        URL(fileURLWithPath: filename).lastPathComponent == filename &&
        !filename.isEmpty && filename.utf8.count <= 512 &&
        filename.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// All generated caches are PNGs. Bound decoding and ignore damaged caches.
    static func loadCachedImage(from url: URL) -> NSImage? {
        guard let container = SharedConfiguration.containerURL else { return nil }
        let prefix = container.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix),
              let confined = BoundedLocalFile.confinedURL(in: container, relativePath:
                String(url.standardizedFileURL.path.dropFirst(prefix.count))),
              confined.standardizedFileURL == url.standardizedFileURL,
              let data = try? BoundedLocalFile.read(url, maximumBytes: maximumCachedImageBytes),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              hasSafeDimensions(source, maximumSide: maximumCustomImageSide),
              let image = thumbnail(from: source) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func isValidDownloadedImage(_ data: Data) -> Bool {
        guard data.count <= maximumSourceSize,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return hasSafeDimensions(source, maximumSide: maximumDownloadedImageSide) && thumbnail(from: source) != nil
    }

    private static func hasSafeDimensions(_ source: CGImageSource, maximumSide: Int) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else { return false }
        return width > 0 && height > 0 && width <= maximumSide && height <= maximumSide
    }

    static func saveImage(from sourceURL: URL) throws -> String {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try BoundedLocalFile.read(sourceURL, maximumBytes: maximumCustomImageSize) }
        catch BoundedLocalFile.ReadError.tooLarge { throw IconAssetError.customImageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw IconAssetError.invalidImage
        }
        return try save(image: customThumbnail(from: source))
    }

    static func saveImage(data: Data) throws -> String {
        guard data.count <= maximumSourceSize,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              hasSafeDimensions(source, maximumSide: maximumDownloadedImageSide),
              let image = thumbnail(from: source) else {
            throw IconAssetError.invalidImage
        }
        return try save(image: image)
    }

    private static func customThumbnail(from source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw IconAssetError.invalidImage
        }
        guard width == height else { throw IconAssetError.customImageNotSquare }
        guard width <= maximumCustomImageSide, height <= maximumCustomImageSide else {
            throw IconAssetError.customImageDimensionsTooLarge
        }
        guard let image = thumbnail(from: source) else { throw IconAssetError.invalidImage }
        return image
    }

    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: outputSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func save(image: CGImage) throws -> String {
        guard let container = SharedConfiguration.containerURL else { throw IconAssetError.containerUnavailable }
        guard let directory = BoundedLocalFile.confinedURL(in: container, relativePath: directoryName) else {
            throw IconAssetError.containerUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).png"
        let destinationURL = directory.appendingPathComponent(filename)
        guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw IconAssetError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IconAssetError.encodingFailed }
        try (data as Data).write(to: destinationURL, options: .atomic)
        return filename
    }

    enum IconAssetError: LocalizedError {
        case containerUnavailable, invalidImage, customImageTooLarge, customImageNotSquare
        case customImageDimensionsTooLarge, encodingFailed

        var errorDescription: String? {
            switch self {
            case .containerUnavailable: "Le dossier partagé des icônes est inaccessible."
            case .invalidImage: "Le fichier sélectionné ne contient pas une image valide."
            case .customImageTooLarge: "L’image personnalisée ne peut pas dépasser 1 Mo."
            case .customImageNotSquare: "L’image personnalisée doit être carrée."
            case .customImageDimensionsTooLarge: "L’image personnalisée ne peut pas dépasser 1024 × 1024 pixels."
            case .encodingFailed: "L’image n’a pas pu être convertie en PNG."
            }
        }
    }
}
