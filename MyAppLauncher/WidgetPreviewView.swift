import AppKit
import SwiftUI
import WidgetKit

struct WidgetPreviewView: View {
    let store: ConfigurationStore
    @State private var selectedFormat: WidgetPreviewFormat = .medium
    @State private var selectedPage = 0
    @State private var installedWidgetSizes: [InstalledWidgetSize] = []
    @State private var hasQueriedInstalledWidgetSizes = false
    @State private var isQueryingInstalledWidgetSizes = false
    @State private var installedWidgetSizesUnavailable = false
    @State private var showingDiagnostics = false
    @State private var showingOverflow = false

    private var items: [PreviewItem] {
        store.items.compactMap { item in
            switch item.kind {
            case .application:
                guard let application = store.application(for: item) else { return nil }
                return PreviewItem(
                    id: item.id,
                    title: application.name,
                    iconURL: IconAssetStore.url(for: item.customIconFilename) ?? application.iconURL,
                    usesSquircle: item.customIconFilename != nil
                )
            case .website:
                return PreviewItem(
                    id: item.id,
                    title: item.title,
                    iconURL: IconAssetStore.url(for: item.websiteCustomIconFilename)
                        ?? IconAssetStore.url(for: item.websiteIconFilename),
                    usesSquircle: true
                )
            }
        }
    }

    private var pagination: WidgetPaginationPlan {
        WidgetPaginationPlan(
            family: selectedFormat.family, itemCount: items.count,
            labelsVisible: store.displaySettings.showsNames, settings: store.gridSettings,
            availableSize: selectedFormat.previewSize, requestedPage: selectedPage
        )
    }

    private var gridPlan: WidgetGridPlan { pagination.grid }

    private var gridSize: CGSize {
        CGSize(width: selectedFormat.previewSize.width,
               height: max(0, selectedFormat.previewSize.height - pagination.navigationHeight(for: selectedFormat.previewSize.width)))
    }

    private var visibleItems: [PreviewItem] {
        Array(items[pagination.itemRange])
    }

    private var overflowItems: [PreviewItem] {
        items.enumerated().compactMap { pagination.itemRange.contains($0.offset) ? nil : $0.element }
    }

    private var displayMetrics: WidgetDisplayMetrics {
        WidgetDisplayMetrics(
            family: selectedFormat.family,
            density: store.displaySettings.density,
            columns: gridPlan.columns,
            rows: gridPlan.rows,
            itemCount: gridPlan.visibleItemCount,
            labelsVisible: store.displaySettings.showsNames,
            availableSize: gridSize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Format du widget")
                .font(.headline)
            Picker("Format", selection: $selectedFormat) {
                ForEach(WidgetPreviewFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text("Aperçu du format sélectionné. La taille réelle est définie par macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Label("\(visibleItems.count) visible\(visibleItems.count == 1 ? "" : "s")", systemImage: "eye")
                Spacer()
                Text("Page \(pagination.pageIndex + 1) sur \(pagination.pageCount)")
            }
            .font(.subheadline.weight(.medium))
            .monospacedDigit()

            previewCard
                .frame(maxWidth: .infinity, alignment: .center)

            overflowSummary

            DisclosureGroup("Diagnostic WidgetKit", isExpanded: $showingDiagnostics) {
                installedWidgetSizesPanel
                Text("Aperçu indicatif : macOS fixe la taille et le fond natif du widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await refreshInstalledWidgetSizes() }
        .onChange(of: selectedFormat) { selectedPage = 0 }
        .onChange(of: store.gridSettings) { selectedPage = 0 }
        .onChange(of: store.displaySettings) { selectedPage = 0 }
        .onChange(of: items.map(\.id)) { selectedPage = 0 }
    }

    private var installedWidgetSizesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Tailles détectées par WidgetKit", systemImage: "macwindow")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if isQueryingInstalledWidgetSizes {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await refreshInstalledWidgetSizes() }
                    } label: {
                        Label("Actualiser les tailles", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("Relire les tailles configurées dans macOS")
                }
            }

            if !hasQueriedInstalledWidgetSizes && isQueryingInstalledWidgetSizes {
                Text("Lecture des widgets configurés…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if installedWidgetSizesUnavailable {
                Text("Impossible de lire les tailles configurées. Réessayez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if installedWidgetSizes.isEmpty {
                Text("Aucune instance My App Launcher détectée.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(installedWidgetSizes.map(\.summary).joined(separator: " · "))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }

            Text("WidgetKit ne précise pas l’emplacement de ces instances.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Sur le bureau : clic droit sur le widget, puis choisissez une taille dans le menu macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func refreshInstalledWidgetSizes() async {
        guard !isQueryingInstalledWidgetSizes else { return }
        isQueryingInstalledWidgetSizes = true
        defer { isQueryingInstalledWidgetSizes = false }

        do {
            let configurations = try await WidgetCenter.shared.currentConfigurations()
            let launcherConfigurations = configurations.filter { $0.kind == "MyAppLauncherWidget" }
            installedWidgetSizes = WidgetPreviewFormat.allCases.compactMap { format in
                let count = launcherConfigurations.filter { $0.family == format.family }.count
                guard count > 0 else { return nil }
                return InstalledWidgetSize(format: format, count: count)
            }
            installedWidgetSizesUnavailable = false
            hasQueriedInstalledWidgetSizes = true
        } catch {
            installedWidgetSizesUnavailable = true
            hasQueriedInstalledWidgetSizes = true
        }
    }

    private var previewCard: some View {
        let gridColumns = Array(
            repeating: GridItem(.flexible(minimum: displayMetrics.iconSize), spacing: displayMetrics.columnSpacing),
            count: gridPlan.columns
        )

        return Group {
            if visibleItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 34))
                    Text("Aucune application")
                        .font(.headline)
                    Text("Ajoutez des éléments depuis la fenêtre principale.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    LazyVGrid(columns: gridColumns, spacing: displayMetrics.rowSpacing) {
                        ForEach(visibleItems) { item in
                            VStack(spacing: displayMetrics.itemSpacing) {
                                previewIcon(for: item)
                                if store.displaySettings.showsNames {
                                    Text(item.title)
                                        .font(.system(size: displayMetrics.labelFontSize))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(displayMetrics.padding)
                    .frame(height: gridSize.height, alignment: .center)
                    if pagination.pageCount > 1 {
                        WidgetPageDots(plan: pagination, width: selectedFormat.previewSize.width) { index in
                            Button { selectedPage = index } label: {
                                WidgetPageDot(isSelected: index == pagination.pageIndex)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Afficher la page \(index + 1) sur \(pagination.pageCount)")
                            .accessibilityAddTraits(index == pagination.pageIndex ? .isSelected : [])
                            .help("Page \(index + 1) sur \(pagination.pageCount)")
                        } arrowControl: { index, direction, isEnabled in
                            Button { selectedPage = index } label: {
                                WidgetPageArrow(direction: direction, isEnabled: isEnabled)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isEnabled)
                            .accessibilityLabel(direction.label)
                            .help(direction.label)
                        }
                    }
                }
            }
        }
        .frame(width: selectedFormat.previewSize.width, height: selectedFormat.previewSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        .accessibilityLabel("Aperçu du format \(selectedFormat.title)")
    }

    @ViewBuilder
    private func previewIcon(for item: PreviewItem) -> some View {
        if let iconURL = item.iconURL, let image = IconAssetStore.loadCachedImage(from: iconURL) {
            if item.usesSquircle {
                WebsiteIconView(image: image, size: displayMetrics.iconSize)
            } else {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: displayMetrics.iconSize, height: displayMetrics.iconSize)
            }
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: displayMetrics.iconSize * 0.82))
                .frame(width: displayMetrics.iconSize, height: displayMetrics.iconSize)
        }
    }

    private var overflowSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !visibleItems.isEmpty {
                Text("Visibles : \(visibleItems.map(\.title).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if overflowItems.isEmpty {
                Label("Tous les éléments tiennent dans ce format.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DisclosureGroup("Voir les \(overflowItems.count) éléments des autres pages", isExpanded: $showingOverflow) {
                    ForEach(overflowItems) { item in
                        Text(item.title)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption)
                Text("Les points au bas du widget permettent de parcourir les pages. L’ordre reste celui de la liste Contenu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PreviewItem: Identifiable {
    let id: String
    let title: String
    let iconURL: URL?
    let usesSquircle: Bool
}

private enum WidgetPreviewFormat: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge
    case extraLargePortrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Petit"
        case .medium: "Moyen"
        case .large: "Grand"
        case .extraLarge: "Très grand"
        case .extraLargePortrait: "Très grand vertical"
        }
    }

    var family: WidgetFamily {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
        case .extraLarge: .systemExtraLarge
        case .extraLargePortrait: .systemExtraLargePortrait
        }
    }

    var previewSize: CGSize {
        switch self {
        case .small: CGSize(width: 230, height: 230)
        case .medium: CGSize(width: 440, height: 183)
        case .large: CGSize(width: 300, height: 300)
        case .extraLarge: CGSize(width: 460, height: 225)
        case .extraLargePortrait: CGSize(width: 225, height: 460)
        }
    }
}

private struct InstalledWidgetSize: Identifiable {
    let format: WidgetPreviewFormat
    let count: Int

    var id: String { format.id }
    var summary: String { "\(format.title) × \(count)" }
}
