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

    init(date: Date, items: [LauncherDisplayItem], gridSettings: WidgetGridSettings,
         displaySettings: WidgetDisplaySettings, usesStoredPages: Bool = true) {
        self.date = date
        self.items = items
        self.gridSettings = gridSettings
        self.displaySettings = displaySettings
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
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(
            date: .now,
            items: Array(AppCatalog.load().prefix(8)).map { .application($0, customIconFilename: nil) },
            gridSettings: .init(),
            displaySettings: .init(),
            usesStoredPages: false
        )
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
            completion(Timeline(entries: [entry], policy: .never))
        }
    }

    @MainActor
    private func refreshEntry(usesStoredPages: Bool = true) -> LauncherEntry {
        SharedConfiguration.logContainerAvailability(component: "Widget")
        do {
            let configuration = try SharedConfiguration.read()
            let applications = applicationCatalog(for: configuration)
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
            return LauncherEntry(
                date: .now,
                items: ordered,
                gridSettings: configuration.gridSettings,
                displaySettings: configuration.displaySettings,
                usesStoredPages: usesStoredPages
            )
        } catch {
            if let fileURL = SharedConfiguration.fileURL, !FileManager.default.fileExists(atPath: fileURL.path) {
                let applications = applicationCatalog(for: nil)
                SharedConfiguration.logger.notice("Widget using phase 1 catalog until shared configuration is initialized")
                return LauncherEntry(
                    date: .now,
                    items: applications.map { .application($0, customIconFilename: nil) },
                    gridSettings: .init(),
                    displaySettings: .init()
                )
            }
            SharedConfiguration.logger.error("Widget shared configuration unavailable: \(String(reflecting: error), privacy: .public)")
            return LauncherEntry(date: .now, items: [], gridSettings: .init(), displaySettings: .init())
        }
    }

    @MainActor
    private func applicationCatalog(for configuration: LauncherConfiguration?) -> [AppRecord] {
        let selectedApplications = configuration?.items.filter { $0.kind == .application } ?? []
        guard configuration == nil || !selectedApplications.isEmpty else { return [] }

        var applications = AppCatalog.load()
        guard configuration != nil else {
            if applications.isEmpty {
                do { try AppCatalog.refresh() }
                catch { AppCatalog.logger.error("Widget catalog initialization failed: \(String(reflecting: error), privacy: .public)") }
                applications = AppCatalog.load()
            }
            return applications
        }

        let cachedByIdentifier = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        let cacheIsComplete = selectedApplications.allSatisfy { item in
            guard let application = cachedByIdentifier[item.target],
                  FileManager.default.fileExists(atPath: application.bundlePath),
                  let iconURL = application.iconURL else { return false }
            return FileManager.default.fileExists(atPath: iconURL.path)
        }
        guard !cacheIsComplete else { return applications }

        do { try AppCatalog.refresh() }
        catch { AppCatalog.logger.error("Widget catalog refresh failed: \(String(reflecting: error), privacy: .public)") }
        applications = AppCatalog.load()
        return applications
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
                    ContentUnavailableView("Aucune application", systemImage: "square.grid.2x2", description: Text("Le catalogue des applications est en cours de préparation. Réessayez dans quelques instants."))
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
            if let url = item.iconURL, let image = NSImage(contentsOf: url) {
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
