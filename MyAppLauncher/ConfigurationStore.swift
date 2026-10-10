import AppKit
import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class ConfigurationStore {
    var applications: [AppRecord] = AppCatalog.load()
    var items: [LauncherItem] = []
    var gridSettings = WidgetGridSettings()
    var displaySettings = WidgetDisplaySettings()
    var errorMessage: String?
    var isRefreshing = false
    var canEdit = false
    private var attemptedWebsiteIconIDs = Set<String>()
    private var fetchingWebsiteIconIDs = Set<String>()

    init() { reload() }

    func reload() {
        applications = AppCatalog.load()
        do {
            let configuration = try SharedConfiguration.read()
            items = configuration.items
            gridSettings = configuration.gridSettings
            displaySettings = configuration.displaySettings
            errorMessage = nil
            canEdit = true
            fetchMissingWebsiteIcons()
        } catch {
            items = []
            canEdit = false
            errorMessage = "La configuration partagée est inaccessible : \(error.localizedDescription)"
        }
    }

    func refreshApplications() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try AppCatalog.refresh()
            applications = AppCatalog.load()
            try SharedConfiguration.seedIfMissing(applications: applications)
            let configuration = try SharedConfiguration.read()
            items = configuration.items
            gridSettings = configuration.gridSettings
            displaySettings = configuration.displaySettings
            errorMessage = nil
            canEdit = true
            fetchMissingWebsiteIcons()
            WidgetCenter.shared.reloadTimelines(ofKind: "MyAppLauncherWidget")
        } catch {
            errorMessage = "Actualisation impossible : \(error.localizedDescription)"
        }
    }

    func contains(_ application: AppRecord) -> Bool {
        items.contains { $0.id == "app:\(application.id)" }
    }

    func toggle(_ application: AppRecord) {
        var updated = items
        if let index = updated.firstIndex(where: { $0.id == "app:\(application.id)" }) {
            updated.remove(at: index)
        } else {
            updated.insert(.application(application.id), at: 0)
        }
        save(updated)
    }

    func addApplications(_ applications: [AppRecord]) {
        let existing = Set(items.map(\.id))
        let additions = applications.filter { !existing.contains("app:\($0.id)") }
        guard !additions.isEmpty else { return }
        save(additions.map { LauncherItem.application($0.id) } + items)
    }

    func remove(_ item: LauncherItem) {
        save(items.filter { $0.id != item.id })
    }

    func removeItems(withIDs ids: Set<String>) {
        guard !ids.isEmpty else { return }
        save(items.filter { !ids.contains($0.id) })
    }

    func removeAllApplications() {
        save(items.filter { $0.kind != .application })
    }

    func move(_ item: LauncherItem, by distance: Int) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              items.indices.contains(index + distance) else { return }
        var updated = items
        updated.swapAt(index, index + distance)
        save(updated)
    }

    func moveToTop(_ item: LauncherItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index > 0 else { return }
        var updated = items
        updated.remove(at: index)
        updated.insert(item, at: 0)
        save(updated)
    }

    func moveItems(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty,
              offsets.allSatisfy(items.indices.contains),
              (0...items.count).contains(destination) else { return }
        let moving = offsets.map { items[$0] }
        var updated = items.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertionIndex = destination - offsets.filter { $0 < destination }.count
        updated.insert(contentsOf: moving, at: insertionIndex)
        guard updated != items else { return }
        save(updated)
    }

    func moveItem(withID draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              let draggedIndex = items.firstIndex(where: { $0.id == draggedID }),
              items.contains(where: { $0.id == targetID }) else { return }
        var updated = items
        let dragged = updated.remove(at: draggedIndex)
        guard let targetIndex = updated.firstIndex(where: { $0.id == targetID }) else { return }
        updated.insert(dragged, at: targetIndex + (after ? 1 : 0))
        guard updated != items else { return }
        save(updated)
    }

    func setGridMode(_ mode: WidgetGridSettings.Mode) {
        var updated = gridSettings
        updated.mode = mode
        _ = save(items, gridSettings: updated)
    }

    func setManualColumnCount(_ count: Int) {
        var updated = gridSettings
        updated.manualColumnCount = min(max(count, 1), WidgetGridSettings.maximumManualColumns)
        _ = save(items, gridSettings: updated)
    }

    func setShowsNames(_ showsNames: Bool) {
        var updated = displaySettings
        updated.showsNames = showsNames
        _ = save(items, displaySettings: updated)
    }

    func setDensity(_ density: WidgetDisplaySettings.Density) {
        var updated = displaySettings
        updated.density = density
        _ = save(items, displaySettings: updated)
    }

    @discardableResult
    func addWebsite(title: String, address: String) -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = cleanAddress.contains("://") ? cleanAddress : "https://\(cleanAddress)"
        guard !cleanTitle.isEmpty, let url = LaunchRoute.validWebsiteURL(candidate) else {
            errorMessage = "Indiquez un nom et une adresse web HTTP ou HTTPS valide."
            return false
        }
        var updated = items
        let item = LauncherItem.website(title: cleanTitle, url: url)
        updated.insert(item, at: 0)
        guard save(updated) else { return false }
        scheduleWebsiteIconFetch(for: item.id)
        return true
    }

    func setCustomIcon(for itemID: String, from sourceURL: URL) {
        guard items.contains(where: { $0.id == itemID }) else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let filename = try IconAssetStore.saveImage(from: sourceURL)
                await self?.applyCustomIcon(filename, for: itemID)
            } catch {
                let message = error.localizedDescription
                await self?.reportCustomIconFailure(message)
            }
        }
    }

    private func applyCustomIcon(_ filename: String, for itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        var updated = items
        if updated[index].kind == .website {
            updated[index].websiteCustomIconFilename = filename
        } else {
            updated[index].customIconFilename = filename
        }
        _ = save(updated)
    }

    private func reportCustomIconFailure(_ message: String) {
        errorMessage = "Impossible d’utiliser cette image : \(message)"
    }

    func restoreDefaultIcon(for itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        var updated = items
        if updated[index].kind == .website {
            updated[index].websiteCustomIconFilename = nil
        } else {
            updated[index].customIconFilename = nil
        }
        _ = save(updated)
    }

    func refreshWebsiteIcon(for itemID: String) {
        scheduleWebsiteIconFetch(for: itemID, retry: true)
    }

    func application(for item: LauncherItem) -> AppRecord? {
        guard item.kind == .application else { return nil }
        return applications.first { $0.id == item.target }
    }

    @discardableResult
    private func save(
        _ updated: [LauncherItem],
        gridSettings updatedGridSettings: WidgetGridSettings? = nil,
        displaySettings updatedDisplaySettings: WidgetDisplaySettings? = nil
    ) -> Bool {
        guard canEdit else {
            errorMessage = "La configuration partagée doit être accessible avant toute modification."
            return false
        }
        do {
            let settings = updatedGridSettings ?? gridSettings
            let appearance = updatedDisplaySettings ?? displaySettings
            let configuration = LauncherConfiguration(
                version: LauncherConfiguration.currentVersion,
                items: updated,
                gridSettings: settings,
                displaySettings: appearance
            )
            try SharedConfiguration.write(configuration)
            items = updated
            gridSettings = settings
            displaySettings = appearance
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "MyAppLauncherWidget")
            return true
        } catch {
            errorMessage = "Enregistrement impossible : \(error.localizedDescription)"
            return false
        }
    }

    private func fetchMissingWebsiteIcons() {
        for item in items where item.kind == .website && item.websiteIconFilename == nil {
            scheduleWebsiteIconFetch(for: item.id)
        }
    }

    private func scheduleWebsiteIconFetch(for itemID: String, retry: Bool = false) {
        guard !fetchingWebsiteIconIDs.contains(itemID) else { return }
        if retry { attemptedWebsiteIconIDs.remove(itemID) }
        guard attemptedWebsiteIconIDs.insert(itemID).inserted else { return }
        Task { await downloadWebsiteIcon(for: itemID) }
    }

    private func downloadWebsiteIcon(for itemID: String) async {
        guard fetchingWebsiteIconIDs.insert(itemID).inserted else { return }
        defer { fetchingWebsiteIconIDs.remove(itemID) }
        guard let item = items.first(where: { $0.id == itemID && $0.kind == .website }),
              let websiteURL = LaunchRoute.validWebsiteURL(item.target) else { return }

        do {
            guard let imageData = try await WebsiteIconFetcher.fetch(for: websiteURL) else {
                SharedConfiguration.logger.notice("No website icon found for \(websiteURL.host ?? "unknown", privacy: .private)")
                return
            }
            let filename = try IconAssetStore.saveImage(data: imageData)
            guard let index = items.firstIndex(where: { $0.id == itemID && $0.kind == .website }) else { return }
            var updated = items
            updated[index].websiteIconFilename = filename
            _ = save(updated)
            SharedConfiguration.logger.notice("Website icon saved for \(websiteURL.host ?? "unknown", privacy: .private)")
        } catch {
            SharedConfiguration.logger.error("Website icon fetch failed: \(String(reflecting: error), privacy: .private)")
        }
    }
}

enum WebsiteIconFetcher {
    private static let maximumHTMLBytes = 2 * 1024 * 1024
    private static let maximumIconBytes = 8 * 1024 * 1024
    private static let maximumIconAttempts = 8

    static func fetch(for pageURL: URL) async throws -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var pageRequest = URLRequest(url: pageURL)
        pageRequest.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (htmlData, pageResponse) = try await read(pageRequest, from: session, maximumBytes: maximumHTMLBytes)
        guard let pageHTTP = pageResponse as? HTTPURLResponse,
              (200..<300).contains(pageHTTP.statusCode),
              let pageMIME = pageHTTP.mimeType?.lowercased(),
              pageMIME == "text/html" || pageMIME == "application/xhtml+xml" else { return nil }

        let resolvedPageURL = pageResponse.url ?? pageURL
        guard LaunchRoute.validWebsiteURL(resolvedPageURL.absoluteString) != nil else { return nil }
        let html = String(decoding: htmlData, as: UTF8.self)
        for iconURL in iconURLs(in: html, relativeTo: resolvedPageURL) {
            var iconRequest = URLRequest(url: iconURL)
            iconRequest.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await read(iconRequest, from: session, maximumBytes: maximumIconBytes),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  response.url.flatMap({ LaunchRoute.validWebsiteURL($0.absoluteString) }) != nil,
                  IconAssetStore.isValidDownloadedImage(data) else { continue }
            return data
        }
        return nil
    }

    /// Keep requests finite and reserve one attempt for the standard favicon.
    static func iconURLs(in html: String, relativeTo pageURL: URL) -> [URL] {
        let candidates = iconLinks(in: html, relativeTo: pageURL).sorted {
            $0.pixelScore == $1.pixelScore ? $0.sourceOrder < $1.sourceOrder : $0.pixelScore > $1.pixelScore
        }
        var seen = Set<String>()
        var urls: [URL] = []
        for candidate in candidates {
            guard urls.count < maximumIconAttempts - 1 else { break }
            guard seen.insert(candidate.url.absoluteString).inserted else { continue }
            urls.append(candidate.url)
        }
        if let favicon = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL,
           seen.insert(favicon.absoluteString).inserted { urls.append(favicon) }
        return urls
    }

    private static func read(_ request: URLRequest, from session: URLSession, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > maximumBytes { throw FetchError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw FetchError.responseTooLarge }
        }
        return (data, response)
    }

    private static func iconLinks(in html: String, relativeTo pageURL: URL) -> [WebsiteIconCandidate] {
        let tagPattern = #"(?is)<link\b[^>]{0,8192}>"#
        let attributePattern = #"(?is)([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern),
              let attributeRegex = try? NSRegularExpression(pattern: attributePattern) else { return [] }
        let fullRange = NSRange(html.startIndex..., in: html)
        var results: [WebsiteIconCandidate] = []

        for tagMatch in tagRegex.matches(in: html, range: fullRange) {
            guard results.count < 128 else { break }
            guard let tagRange = Range(tagMatch.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let tagNSRange = NSRange(tag.startIndex..., in: tag)
            var attributes: [String: String] = [:]
            for attributeMatch in attributeRegex.matches(in: tag, range: tagNSRange) {
                guard let keyRange = Range(attributeMatch.range(at: 1), in: tag) else { continue }
                let valueRange = (2...4).compactMap { index -> Range<String.Index>? in
                    guard attributeMatch.range(at: index).location != NSNotFound else { return nil }
                    return Range(attributeMatch.range(at: index), in: tag)
                }.first
                guard let valueRange else { continue }
                attributes[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
            }

            let relations = (attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            guard relations.contains(where: { $0.contains("icon") }),
                  let href = attributes["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.host != nil, url.user == nil, url.password == nil else { continue }
            let sizes = (attributes["sizes"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            let declaredPixels = sizes.compactMap { size -> Int? in
                guard size != "any" else { return 1024 }
                let dimensions = size.split(separator: "x").compactMap { Int($0) }
                guard dimensions.count == 2 else { return nil }
                return min(dimensions[0], dimensions[1])
            }.max() ?? 16
            let isAppleTouchIcon = relations.contains(where: { $0.contains("apple-touch-icon") })
            let isVector = (attributes["type"] ?? "").lowercased().contains("svg") || url.pathExtension.lowercased() == "svg"
            let qualityBonus = (isAppleTouchIcon ? 1.05 : 1.0) * (isVector ? 1.2 : 1.0)
            results.append(WebsiteIconCandidate(
                url: url,
                pixelScore: Double(declaredPixels) * qualityBonus,
                sourceOrder: results.count
            ))
        }
        return results
    }

    private struct WebsiteIconCandidate {
        let url: URL
        let pixelScore: Double
        let sourceOrder: Int
    }

    private enum FetchError: LocalizedError {
        case responseTooLarge
        var errorDescription: String? { "La réponse du site dépasse la taille autorisée." }
    }
}
