import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

@main
struct SecurityTests {
    @MainActor
    static func main() async throws {
        guard let root = SharedConfiguration.containerURL else { fatalError("Missing isolated container") }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1; print("PASS: \(label)") }
            else { failures.append(label); print("FAIL: \(label)") }
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); check(false, label) } catch { check(true, label) }
        }
        func png(width: Int, height: Int) throws -> Data {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }
        func source(_ name: String, data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        }
        func catalog(_ records: [AppRecord]) throws {
            try manager.createDirectory(at: AppCatalog.containerURL!, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: AppCatalog.manifestURL!, options: .atomic)
        }
        let app = AppRecord(bundleIdentifier: "com.example.Safe", name: "Safe",
                            bundlePath: "/Applications/Safe.app", iconFilename: "Icons/safe.png")
        let other = AppRecord(bundleIdentifier: "com.example.Other", name: "Other",
                              bundlePath: "/Applications/Other.app", iconFilename: "Icons/other.png")
        let pngData = try png(width: 64, height: 64)
        let icon = try IconAssetStore.saveImage(data: pngData)
        var appItem = LauncherItem.application(app.id)
        appItem.customIconFilename = icon
        var webItem = LauncherItem.website(title: "Safe site", url: URL(string: "https://example.test/path?q=1")!)
        webItem.websiteIconFilename = icon // Avoid any real network access in fixtures.
        webItem.websiteCustomIconFilename = icon
        let original = LauncherConfiguration(version: 1, items: [appItem, .application(other.id), webItem],
            gridSettings: .init(mode: .manual, manualColumnCount: 3),
            displaySettings: .init(showsNames: false, density: .spacious))
        try catalog([app, other])
        try SharedConfiguration.write(original)
        check(try SharedConfiguration.read() == original, "Configuration, icon overrides and order round-trip")

        for address in ["ftp://example.test", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "https://", "https://user:password@example.test", "myapplauncher://configure", "", "mailto:a@example.test"] {
            check(LaunchRoute.validWebsiteURL(address) == nil, "Reject forbidden or incomplete URL: \(address.prefix(30))")
        }
        for address in ["https://example.test", "http://localhost:8080/test", "https://example.com/path?q=x#fragment", "https://exemple.fr"] {
            check(LaunchRoute.validWebsiteURL(address) != nil, "Accept syntactically valid HTTP(S)")
        }
        for value in ["", "invalid\nID", String(repeating: "a", count: 256)] {
            check(!LaunchRoute.isValidBundleIdentifier(value), "Reject invalid installation identifier")
        }
        for value in ["myapplauncher://launch/path?bundle=com.example.Safe", "myapplauncher://launch:80?bundle=com.example.Safe", "myapplauncher://user@launch?bundle=com.example.Safe", "myapplauncher://launch?bundle=com.example.Safe&bundle=com.example.Other", "myapplauncher://configure?unexpected=true", "myapplauncher://open-web?url=file:///etc/passwd", "myapplauncher://unknown", "myapplauncher://launch?bundle=com.example.Safe#fragment"] {
            check(URL(string: value).flatMap(LaunchRoute.destination) == nil, "Reject malformed launcher route")
        }
        if case .application(let value) = LaunchRoute.destination(from: LaunchRoute.url(bundleIdentifier: app.id)) {
            check(value == app.id, "Valid app route retains exact catalog identity")
        } else { check(false, "Valid app route") }
        if case .website(let value) = LaunchRoute.destination(from: LaunchRoute.websiteURL(URL(string: webItem.target)!)) {
            check(value.absoluteString == webItem.target, "Valid website route preserves URL encoding")
        } else { check(false, "Valid web route") }
        var state: UInt64 = 12345
        let alphabet = Array("abc0123:/?#%@=&\n ")
        for _ in 0..<10_000 {
            state = state &* 6364136223846793005 &+ 1
            let count = Int(state % 256)
            var text = ""
            for _ in 0..<count {
                state = state &* 6364136223846793005 &+ 1
                text.append(alphabet[Int(state % UInt64(alphabet.count))])
            }
            _ = LaunchRoute.validWebsiteURL(text)
            if let url = URL(string: text) { _ = LaunchRoute.destination(from: url) }
        }
        check(true, "10,000 deterministic malformed URL inputs: no crash")

        try catalog([app, app])
        rejects("Duplicate catalog identities fail before widget dictionary construction") { _ = try AppCatalog.read() }
        check(AppCatalog.load().isEmpty, "Damaged catalog has a recoverable empty fallback")
        check(try SharedConfiguration.read() == original, "Damaged catalog does not delete selected items")
        for path in ["../outside.png", "/tmp/outside.png", "Icons/../outside.png", "Icons/subdir/icon.png", "Icons//icon.png", "Icons/icon.txt"] {
            let malformed = AppRecord(bundleIdentifier: app.bundleIdentifier, name: app.name,
                bundlePath: app.bundlePath, iconFilename: path)
            try catalog([malformed])
            rejects("Reject catalog icon traversal or invalid path") { _ = try AppCatalog.read() }
        }
        try catalog([app, other])
        let oversizedCatalog = Data(repeating: 32, count: 8 * 1024 * 1024 + 1)
        try oversizedCatalog.write(to: AppCatalog.manifestURL!, options: .atomic)
        rejects("Reject oversized catalog before JSON decoding") { _ = try AppCatalog.read() }
        try catalog([app, other])

        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: SharedConfiguration.fileURL!, options: .atomic)
        let locked = ConfigurationStore()
        check(!locked.canEdit && locked.errorMessage != nil, "Corrupt configuration disables editing and reports an error")
        locked.toggle(app)
        try SharedConfiguration.seedIfMissing(applications: [app])
        check(try Data(contentsOf: SharedConfiguration.fileURL!) == corrupt, "Read failure, editing and seeding never overwrite existing corrupt data")
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: SharedConfiguration.fileURL!, options: .atomic)
        rejects("Reject oversized configuration") { _ = try SharedConfiguration.read() }
        try SharedConfiguration.write(original)
        var duplicate = original; duplicate.items.append(appItem)
        rejects("Reject duplicate configuration entries before writing") { try SharedConfiguration.write(duplicate) }
        check(try SharedConfiguration.read() == original, "Failed configuration write preserves previous file")
        var huge = original; huge.items[2].title = String(repeating: "x", count: 4 * 1024 * 1024)
        rejects("Oversized encoded configuration is rejected before atomic replacement") { try SharedConfiguration.write(huge) }
        check(try SharedConfiguration.read() == original, "Oversized write preserves original configuration")

        let store = ConfigurationStore()
        store.moveItem(withID: webItem.id, relativeTo: appItem.id, after: false)
        store.reload()
        check(store.items.map(\.id) == [webItem.id, appItem.id, "app:\(other.id)"], "Reorder persists across store reload")
        check(store.gridSettings == original.gridSettings && store.displaySettings == original.displaySettings,
              "Reordering preserves appearance and layout")
        store.setShowsNames(true); store.setDensity(.compact); store.setGridMode(.automatic); store.setManualColumnCount(8)
        store.reload()
        check(store.displaySettings.showsNames && store.displaySettings.density == .compact && store.gridSettings.mode == .automatic && store.gridSettings.manualColumnCount == 8,
              "Settings persist across reload")
        let beforeInvalidDrop = store.items
        store.moveItem(withID: "unknown", relativeTo: appItem.id, after: true)
        store.moveItems(from: IndexSet(integer: 1000), to: 0)
        check(store.items == beforeInvalidDrop, "Invalid drag identifiers and indices leave selections intact")

        for filename in ["../outside.png", "/tmp/outside.png", "a/b.png", "a\n.png", "icon.jpg"] {
            check(!IconAssetStore.isValidFilename(filename), "Reject unsafe icon filename")
        }
        let validURL = try source("valid.png", data: pngData)
        let imported = try IconAssetStore.saveImage(from: validURL)
        check(IconAssetStore.url(for: imported).flatMap(IconAssetStore.loadCachedImage) != nil, "Valid square transparent PNG imports and loads")
        let importedURL = IconAssetStore.url(for: imported)!
        let firstDecoded = IconAssetStore.loadCachedCGImage(from: importedURL)!
        let secondDecoded = IconAssetStore.loadCachedCGImage(from: importedURL)!
        check(firstDecoded === secondDecoded, "Unchanged validated PNG reuses its decoded image")
        let oldModificationDate = try manager.attributesOfItem(atPath: importedURL.path)[.modificationDate] as! Date
        try png(width: 128, height: 128).write(to: importedURL, options: .atomic)
        try manager.setAttributes([.modificationDate: oldModificationDate], ofItemAtPath: importedURL.path)
        let replacedDecoded = IconAssetStore.loadCachedCGImage(from: importedURL)!
        check(firstDecoded !== replacedDecoded && replacedDecoded.width == 128,
              "Replacing an icon at the same path and modification date invalidates the decoded cache")
        try pngData.write(to: importedURL, options: .atomic)
        check(IconAssetStore.loadCachedCGImage(from: importedURL)?.width == 64,
              "Restoring an icon invalidates the prior version without restarting")
        let atLimit = try source("limit.png", data: png(width: 1024, height: 1024))
        check(!(try IconAssetStore.saveImage(from: atLimit)).isEmpty, "1024 x 1024 custom image accepted")
        let rectangular = try source("rectangle.png", data: png(width: 64, height: 32))
        rejects("Reject rectangular manual icon") { _ = try IconAssetStore.saveImage(from: rectangular) }
        let tooWide = try source("too-wide.png", data: png(width: 1025, height: 1025))
        rejects("Reject custom image larger than 1024") { _ = try IconAssetStore.saveImage(from: tooWide) }
        let tooHeavy = try source("too-heavy.png", data: Data(repeating: 0, count: 1024 * 1024 + 1))
        rejects("Reject custom image larger than 1 MiB") { _ = try IconAssetStore.saveImage(from: tooHeavy) }
        let broken = try source("broken.png", data: Data("not an image".utf8))
        rejects("Reject corrupt manual image") { _ = try IconAssetStore.saveImage(from: broken) }
        let oversizedPixels = try png(width: 8193, height: 1)
        rejects("Reject excessive downloaded pixel dimensions") { _ = try IconAssetStore.saveImage(data: oversizedPixels) }
        check(!IconAssetStore.isValidDownloadedImage(oversizedPixels), "Downloaded image header enforces pixel bounds")
        check(IconAssetStore.isValidDownloadedImage(try png(width: 64, height: 32)), "Automatic favicon retains rectangular-source support")
        rejects("Reject malformed favicon bytes") { _ = try IconAssetStore.saveImage(data: Data("bad".utf8)) }
        let cached = IconAssetStore.url(for: imported)!
        let goodCache = try Data(contentsOf: cached)
        try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: cached, options: .atomic)
        check(IconAssetStore.loadCachedImage(from: cached) == nil, "Oversized icon cache uses fallback")
        try corrupt.write(to: cached, options: .atomic)
        check(IconAssetStore.loadCachedImage(from: cached) == nil, "Corrupt icon cache uses fallback")
        try goodCache.write(to: cached, options: .atomic)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.png")
        try pngData.write(to: outside)
        let symlink = cached.deletingLastPathComponent().appendingPathComponent("outside.png")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: outside)
        check(IconAssetStore.url(for: "outside.png") == nil && IconAssetStore.loadCachedImage(from: symlink) == nil,
              "Icon symlink cannot read outside App Group")
        check(IconAssetStore.loadCachedImage(from: outside) == nil, "Direct external cache URL rejected")
        store.setCustomIcon(for: appItem.id, from: broken)
        for _ in 0..<100 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
        check(store.errorMessage != nil && store.items.first(where: { $0.id == appItem.id })?.customIconFilename == icon,
              "Asynchronous corrupt import keeps previous app icon and companion state")
        store.errorMessage = nil
        store.setCustomIcon(for: webItem.id, from: broken)
        for _ in 0..<100 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
        check(store.errorMessage != nil && store.items.first(where: { $0.id == webItem.id })?.websiteCustomIconFilename == icon,
              "Asynchronous corrupt import keeps previous web icon")

        let pageURL = URL(string: "https://example.test/path")!
        let links = (0..<200).map { "<link rel='icon' href='/icon\($0).png' sizes='64x64'>" }.joined()
        let candidates = WebsiteIconFetcher.iconURLs(in: links, relativeTo: pageURL)
        check(candidates.count <= 8 && candidates.last?.path == "/favicon.ico", "At most eight favicon requests, including fallback")
        let fallbackEighth = (0..<7).map { "<link rel='icon' href='/priority\($0).png'>" }.joined()
            + "<link rel='icon' href='/favicon.ico'>"
        check(WebsiteIconFetcher.iconURLs(in: fallbackEighth, relativeTo: pageURL).last?.path == "/favicon.ico",
              "Standard favicon is retained when it is the eighth distinct candidate")
        let repeated = String(repeating: "<link rel='icon' href='/icon.png'>", count: 200)
        check(WebsiteIconFetcher.iconURLs(in: repeated, relativeTo: pageURL).count == 2, "Repeated favicon candidates deduplicated")
        let unsafeLinks = "<link rel='icon' href='file:///etc/passwd'><link rel='icon' href='javascript:evil'><link rel='icon' href='https://user:pass@example.test/icon.png'>"
        check(WebsiteIconFetcher.iconURLs(in: unsafeLinks, relativeTo: pageURL).map(\.path) == ["/favicon.ico"], "Favicon candidates reject executable and credential schemes")

        let fixture = SecurityNetworkFixture.shared
        fixture.reset(icon: pngData)
        let fetched = try await WebsiteIconFetcher.fetch(for: URL(string: "https://security-fixture.test/page")!)
        check(fetched == pngData && fixture.requests == ["/page", "/valid.png"],
              "Mocked favicon discovery downloads only HTML and the valid image")
        fixture.reset(icon: pngData)
        do {
            _ = try await WebsiteIconFetcher.fetch(for: URL(string: "https://security-fixture.test/large-html")!)
            check(false, "Reject declared oversized HTML response")
        } catch { check(true, "Reject declared oversized HTML response") }
        fixture.reset(icon: pngData)
        do {
            _ = try await WebsiteIconFetcher.fetch(for: URL(string: "https://security-fixture.test/lying-html")!)
            check(false, "Reject oversized HTML stream without a declared size")
        } catch { check(true, "Reject oversized HTML stream without a declared size") }
        fixture.reset(icon: pngData)
        let fallback = try await WebsiteIconFetcher.fetch(for: URL(string: "https://security-fixture.test/large-icon-page")!)
        check(fallback == pngData && fixture.requests == ["/large-icon-page", "/large-icon.png", "/favicon.ico"],
              "Oversized favicon is skipped and a valid fallback is retained")
        fixture.reset(icon: pngData)
        let absent = try await WebsiteIconFetcher.fetch(for: URL(string: "https://security-fixture.test/bad-icons")!)
        check(absent == nil && fixture.requests.count == 9,
              "Malicious page cannot trigger more than eight icon requests")

        let revision = WidgetPageStateStore.revision(itemIDs: original.items.map(\.id), grid: original.gridSettings, display: original.displaySettings)
        for family in WidgetPageStateStore.families {
            try WidgetPageStateStore.save(pageIndex: 1, familyRawValue: family.rawValue, revision: revision)
            check(WidgetPageStateStore.pages(revision: revision)[family.rawValue] == 1, "Page persists in native family \(family.rawValue)")
        }
        rejects("Invalid widget family cannot create a state file") { try WidgetPageStateStore.save(pageIndex: 0, familyRawValue: -1, revision: revision) }
        rejects("Negative page rejected") { try WidgetPageStateStore.save(pageIndex: -1, familyRawValue: WidgetFamily.systemSmall.rawValue, revision: revision) }
        let pageFile = root.appendingPathComponent("WidgetPagination-\(WidgetFamily.systemSmall.rawValue).json")
        try Data(repeating: 0, count: 4097).write(to: pageFile, options: .atomic)
        check(WidgetPageStateStore.pages(revision: revision)[WidgetFamily.systemSmall.rawValue] == nil, "Oversized page state safely returns to first page")
        check(try Data(contentsOf: pageFile).count == 4097, "Corrupt page state is not overwritten on read")
        var scenarios = 0
        for family in WidgetPageStateStore.families {
            let metrics = WidgetGridMetrics(family: family)
            for count in [0, 1, 2, 4, 6, 8, 10, 16, 18, 26] {
                for mode in [WidgetGridSettings.Mode.automatic, .manual] {
                    for columns in [1, 3, 8] {
                        for showsNames in [true, false] {
                            let size = CGSize(width: metrics.aspectRatio * 400, height: 400)
                            let settings = WidgetGridSettings(mode: mode, manualColumnCount: columns)
                            let first = WidgetPaginationPlan(family: family, itemCount: count, labelsVisible: showsNames,
                                settings: settings, availableSize: size, requestedPage: 0)
                            var combined: [Int] = []
                            for page in 0..<first.pageCount {
                                let plan = WidgetPaginationPlan(family: family, itemCount: count, labelsVisible: showsNames,
                                    settings: settings, availableSize: size, requestedPage: page)
                                combined += plan.itemRange
                            }
                            if combined != Array(0..<count) || first.grid.columns > metrics.maximumColumns || first.grid.rows > metrics.maximumRows {
                                check(false, "Grid/pagination scenario \(scenarios)")
                            }
                            scenarios += 1
                        }
                    }
                }
            }
        }
        check(true, "\(scenarios) grid and pagination scenarios cover each item once")
        try SharedConfiguration.write(original)
        check(try SharedConfiguration.read() == original, "Final isolated configuration preserves original preferences and icons")
        print("RESULT: \(passed) checks passed, \(failures.count) failed. No live data or real network access.")
        if !failures.isEmpty { throw NSError(domain: "SecurityTests", code: failures.count, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
