import AppKit
import AppIntents
import SwiftUI
import WidgetKit

struct LauncherEntry: TimelineEntry {
    let date: Date
    let items: [LauncherDisplayItem]
    let gridSettings: WidgetGridSettings
    let displaySettings: WidgetDisplaySettings
    let paginationRevision: String
    let pageIndices: [Int: Int]
    let isAwaitingConfiguration: Bool

    init(date: Date, items: [LauncherDisplayItem], gridSettings: WidgetGridSettings,
         displaySettings: WidgetDisplaySettings, usesStoredPages: Bool = true,
         isAwaitingConfiguration: Bool = false) {
        self.date = date
        self.items = items
        self.gridSettings = gridSettings
        self.displaySettings = displaySettings
        self.isAwaitingConfiguration = isAwaitingConfiguration
        let revision = WidgetPageStateStore.revision(itemIDs: items.map(\.id), grid: gridSettings, display: displaySettings)
        paginationRevision = revision
        pageIndices = usesStoredPages ? WidgetPageStateStore.pages(revision: revision) : [:]
    }
}

enum LauncherDisplayItem: Identifiable {
    case application(AppRecord, customIconFilename: String?)
    case website(LauncherItem)

    var id: String {
        switch self {
        case .application(let app, _): "app:\(app.id)"
        case .website(let link): link.id
        }
    }

    var title: String {
        switch self {
        case .application(let app, _): app.name
        case .website(let link): link.title
        }
    }

    var iconURL: URL? {
        switch self {
        case .application(let app, let customIconFilename):
            return IconAssetStore.url(for: customIconFilename) ?? app.iconURL
        case .website(let link):
            return IconAssetStore.url(for: link.websiteCustomIconFilename) ?? IconAssetStore.url(for: link.websiteIconFilename)
        }
    }

    var isWebsite: Bool {
        if case .website = self { return true }
        return false
    }

    var usesSquircle: Bool {
        switch self {
        case .application(_, let customIconFilename): customIconFilename != nil
        case .website: true
        }
    }

    var destination: URL {
        switch self {
        case .application(let app, _): LaunchRoute.url(bundleIdentifier: app.id)
        case .website(let link): LaunchRoute.websiteURL(LaunchRoute.validWebsiteURL(link.target)!)
        }
    }
}

struct LauncherProvider: TimelineProvider {
    // This cache is scoped to the extension process. A cold launch with no
    // readable configuration stays empty rather than guessing a selection.
    @MainActor private static var lastValidEntry: LauncherEntry?

    func placeholder(in context: Context) -> LauncherEntry {
        guard let configuration = try? SharedConfiguration.read() else {
            return LauncherEntry(date: .now, items: [], gridSettings: .init(),
                                 displaySettings: .init(), usesStoredPages: false,
                                 isAwaitingConfiguration: true)
        }
        return makeEntry(configuration: configuration, applications: AppCatalog.load(), usesStoredPages: false)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (LauncherEntry) -> Void) {
        let usesStoredPages = !context.isPreview
        Task { @MainActor in
            let entry = refreshEntry(usesStoredPages: usesStoredPages)
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<LauncherEntry>) -> Void) {
        Task { @MainActor in
            let entry = refreshEntry()
            // A transient read failure must not produce a permanent empty
            // timeline. WidgetKit controls the actual time of the next request.
            let policy: TimelineReloadPolicy = entry.isAwaitingConfiguration
                ? .after(Date.now.addingTimeInterval(5 * 60))
                : .never
            completion(Timeline(entries: [entry], policy: policy))
        }
    }

    @MainActor
    private func refreshEntry(usesStoredPages: Bool = true) -> LauncherEntry {
        SharedConfiguration.logContainerAvailability(component: "Widget")
        do {
            let configuration = try SharedConfiguration.read()
            let applications = try applicationCatalog(for: configuration)
            let byIdentifier = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
            let customWebsiteItems = configuration.items.filter {
                $0.kind == .website && $0.websiteCustomIconFilename != nil
            }
            let readableCustomWebsiteIcons = customWebsiteItems.filter { item in
                guard let iconURL = IconAssetStore.url(for: item.websiteCustomIconFilename) else { return false }
                return FileManager.default.fileExists(atPath: iconURL.path)
            }.count
            SharedConfiguration.logger.notice(
                "Widget custom website icons: configured=\(customWebsiteItems.count), readable=\(readableCustomWebsiteIcons)"
            )
            let ordered = configuration.items.compactMap { item -> LauncherDisplayItem? in
                switch item.kind {
                case .application:
                    guard let app = byIdentifier[item.target] else { return nil }
                    return .application(app, customIconFilename: item.customIconFilename)
                case .website:
                    return .website(item)
                }
            }
            SharedConfiguration.logger.notice("Widget read shared configuration: \(configuration.items.count) items, \(ordered.count) available")
            let entry = LauncherEntry(
                date: .now,
                items: ordered,
                gridSettings: configuration.gridSettings,
                displaySettings: configuration.displaySettings,
                usesStoredPages: usesStoredPages
            )
            Self.lastValidEntry = entry
            return entry
        } catch {
            SharedConfiguration.logger.error("Widget shared configuration unavailable: \(String(reflecting: error), privacy: .private)")
            if let previous = Self.lastValidEntry {
                return LauncherEntry(date: .now, items: previous.items,
                                     gridSettings: previous.gridSettings,
                                     displaySettings: previous.displaySettings,
                                     usesStoredPages: usesStoredPages,
                                     isAwaitingConfiguration: true)
            }
            return LauncherEntry(date: .now, items: [], gridSettings: .init(),
                                 displaySettings: .init(), usesStoredPages: usesStoredPages,
                                 isAwaitingConfiguration: true)
        }
    }

    private func makeEntry(configuration: LauncherConfiguration, applications: [AppRecord],
                           usesStoredPages: Bool) -> LauncherEntry {
        let byIdentifier = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        let ordered = configuration.items.compactMap { item -> LauncherDisplayItem? in
            switch item.kind {
            case .application:
                guard let app = byIdentifier[item.target] else { return nil }
                return .application(app, customIconFilename: item.customIconFilename)
            case .website:
                return .website(item)
            }
        }
        return LauncherEntry(date: .now, items: ordered,
                             gridSettings: configuration.gridSettings,
                             displaySettings: configuration.displaySettings,
                             usesStoredPages: usesStoredPages)
    }

    @MainActor
    private func applicationCatalog(for configuration: LauncherConfiguration) throws -> [AppRecord] {
        let selectedApplications = configuration.items.filter { $0.kind == .application }
        guard !selectedApplications.isEmpty else { return [] }

        // Distinguish an unreadable catalog from a valid empty catalog, so an
        // access failure cannot replace the last valid display with no apps.
        let applications = try AppCatalog.read()
        let cachedByIdentifier = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        let cacheIsComplete = selectedApplications.allSatisfy { item in
            guard let application = cachedByIdentifier[item.target],
                  FileManager.default.fileExists(atPath: application.bundlePath),
                  let iconURL = application.iconURL else { return false }
            return FileManager.default.fileExists(atPath: iconURL.path)
        }
        guard !cacheIsComplete else { return applications }

        try AppCatalog.refresh()
        return try AppCatalog.read()
    }

}

struct LauncherWidgetView: View {
    let entry: LauncherEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        GeometryReader { geometry in
            let pagination = WidgetPaginationPlan(
                family: family, itemCount: entry.items.count,
                labelsVisible: entry.displaySettings.showsNames, settings: entry.gridSettings,
                availableSize: geometry.size, requestedPage: entry.pageIndices[family.rawValue] ?? 0
            )
            let gridSize = CGSize(width: geometry.size.width,
                                  height: max(0, geometry.size.height - pagination.navigationHeight(for: geometry.size.width)))
            let metrics = WidgetDisplayMetrics(
                family: family, density: entry.displaySettings.density,
                columns: pagination.grid.columns, rows: pagination.grid.rows,
                itemCount: pagination.grid.visibleItemCount,
                labelsVisible: entry.displaySettings.showsNames, availableSize: gridSize
            )
            let visibleItems = Array(entry.items[pagination.itemRange])
            let columns = Array(
                repeating: GridItem(.flexible(minimum: metrics.iconSize), spacing: metrics.columnSpacing),
                count: pagination.grid.columns
            )

            Group {
                if visibleItems.isEmpty {
                    ContentUnavailableView(
                        entry.isAwaitingConfiguration ? "Actualisation en cours" : "Aucun élément",
                        systemImage: "square.grid.2x2",
                        description: Text(entry.isAwaitingConfiguration
                            ? "La sélection sera affichée dès que les données seront accessibles."
                            : "Choisissez vos applications et liens dans le compagnon.")
                    )
                } else {
                    VStack(spacing: 0) {
                        LazyVGrid(columns: columns, spacing: metrics.rowSpacing) {
                            ForEach(visibleItems) { item in
                                Link(destination: item.destination) {
                                    itemView(item, metrics: metrics)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.title)
                            }
                        }
                        .padding(metrics.padding)
                        .frame(maxWidth: .infinity)
                        .frame(height: gridSize.height, alignment: .center)
                        .invalidatableContent()

                        if pagination.pageCount > 1 {
                            WidgetPageDots(plan: pagination, width: geometry.size.width) { index in
                                Button(intent: ChangeWidgetPageIntent(
                                    familyRawValue: family.rawValue, pageIndex: index,
                                    revision: entry.paginationRevision
                                )) {
                                    WidgetPageDot(isSelected: index == pagination.pageIndex)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Afficher la page \(index + 1) sur \(pagination.pageCount)")
                                .accessibilityAddTraits(index == pagination.pageIndex ? .isSelected : [])
                            } arrowControl: { index, direction, isEnabled in
                                Button(intent: ChangeWidgetPageIntent(
                                    familyRawValue: family.rawValue, pageIndex: index,
                                    revision: entry.paginationRevision
                                )) {
                                    WidgetPageArrow(direction: direction, isEnabled: isEnabled)
                                }
                                .buttonStyle(.plain)
                                .disabled(!isEnabled)
                                .accessibilityLabel(direction.label)
                            }
                        }
                    }
                }
            }
            .containerBackground(for: .widget) { Color.clear }
        }
        .widgetURL(LaunchRoute.configurationURL)
    }

    private func itemView(_ item: LauncherDisplayItem, metrics: WidgetDisplayMetrics) -> some View {
        VStack(spacing: metrics.itemSpacing) {
            if let url = item.iconURL, let image = IconAssetStore.loadCachedImage(from: url) {
                if item.usesSquircle {
                    WebsiteIconView(image: image, size: metrics.iconSize)
                } else {
                    Image(nsImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFit()
                        .frame(width: metrics.iconSize, height: metrics.iconSize)
                }
            } else {
                Image(systemName: item.isWebsite ? "globe" : "app.fill")
                    .font(.system(size: metrics.iconSize * 0.82))
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
            }
            if entry.displaySettings.showsNames {
                Text(item.title)
                    .font(.system(size: metrics.labelFontSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct LauncherWidget: Widget {
    let kind = "MyAppLauncherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { entry in
            LauncherWidgetView(entry: entry)
        }
        .configurationDisplayName("My App Launcher")
        .description("Accédez directement à vos applications depuis une grille adaptative.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .systemExtraLargePortrait])
    }
}

@main
struct MyAppLauncherWidgetBundle: WidgetBundle {
    var body: some Widget { LauncherWidget() }
}
