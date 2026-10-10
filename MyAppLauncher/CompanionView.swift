import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CompanionView: View {
    @ObservedObject var updates: LauncherUpdates
    @State private var showingUpdates = false
    @State private var store = ConfigurationStore()
    @State private var search = ""
    @FocusState private var searchIsFocused: Bool
    @State private var websiteTitle = ""
    @State private var websiteAddress = ""
    @State private var selectedItemIDs = Set<String>()
    @State private var selectedCatalogIDs = Set<String>()
    @AppStorage("showAuxiliaryApplications") private var showAuxiliaryApplications = false
    @State private var showingRemoveAllConfirmation = false
    @State private var selectedRightPane: CompanionRightPane = .applications
    @State private var showingImageImporter = false
    @State private var iconImportTargetID: String?
    @State private var dropTargetID: String?

    private var filteredApplications: [AppRecord] {
        store.applications.filter { application in
            (showAuxiliaryApplications || !application.isAuxiliary) &&
            (search.isEmpty || application.name.localizedCaseInsensitiveContains(search) ||
             application.bundleIdentifier.localizedCaseInsensitiveContains(search))
        }
    }

    private var selectedCatalogAdditions: [AppRecord] {
        store.applications.filter { selectedCatalogIDs.contains($0.id) && !store.contains($0) }
    }

    private var selectedMovableItem: LauncherItem? {
        guard selectedItemIDs.count == 1, let id = selectedItemIDs.first else { return nil }
        return store.items.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 0) {
                orderedList
                    .frame(minWidth: 450)
                    .disabled(!store.canEdit)
                Divider()
                rightPane
                    .frame(minWidth: 340)
                    .disabled(!store.canEdit)
            }
            if let errorMessage = store.errorMessage {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        store.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Masquer le message d’erreur")
                    .accessibilityLabel("Masquer le message d’erreur")
                }
                .padding(12)
            }
        }
        .frame(minWidth: 850, minHeight: 560)
        .task { store.reload() }
        .onChange(of: store.items) { _, items in
            selectedItemIDs.formIntersection(Set(items.map(\.id)))
        }
        .onChange(of: filteredApplications.map(\.id)) { _, identifiers in
            selectedCatalogIDs.formIntersection(Set(identifiers))
        }
        .confirmationDialog(
            "Retirer toutes les applications du widget ?",
            isPresented: $showingRemoveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Retirer toutes les applications", role: .destructive) {
                store.removeAllApplications()
                selectedItemIDs.removeAll()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les liens web resteront dans le widget.")
        }
        .fileImporter(isPresented: $showingImageImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            guard let itemID = iconImportTargetID else { return }
            switch result {
            case .success(let urls):
                if let url = urls.first { store.setCustomIcon(for: itemID, from: url) }
            case .failure(let error):
                store.errorMessage = "Sélection d’image impossible : \(error.localizedDescription)"
            }
            iconImportTargetID = nil
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.tint)
            Text("My App Launcher")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(store.items.count) éléments dans le widget")
                .foregroundStyle(.secondary)
            Button { showingUpdates.toggle() } label: {
                Label("Mises à jour", systemImage: "arrow.triangle.2.circlepath")
            }
            .popover(isPresented: $showingUpdates) {
                LauncherUpdateSettings(updates: updates)
            }
        }
        .padding(16)
    }

    private var orderedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsPanel
            Divider()
            HStack(spacing: 8) {
                Text("Contenu")
                    .font(.headline)
                Spacer(minLength: 4)
                Menu {
                    Button("Monter la sélection") {
                        if let item = selectedMovableItem { store.move(item, by: -1) }
                    }
                    .disabled(selectedMovableItem == nil || store.items.first?.id == selectedMovableItem?.id)
                    Button("Descendre la sélection") {
                        if let item = selectedMovableItem { store.move(item, by: 1) }
                    }
                    .disabled(selectedMovableItem == nil || store.items.last?.id == selectedMovableItem?.id)
                    Divider()
                    Button("Retirer la sélection") {
                        store.removeItems(withIDs: selectedItemIDs)
                        selectedItemIDs.removeAll()
                    }
                    .disabled(selectedItemIDs.isEmpty)
                    Divider()
                    Button("Retirer toutes les applications…", role: .destructive) {
                        showingRemoveAllConfirmation = true
                    }
                    .disabled(!store.items.contains { $0.kind == .application })
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            Text("Glissez les lignes pour les réordonner. Le menu Actions permet aussi de les déplacer au clavier.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            List(selection: $selectedItemIDs) {
                ForEach(store.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .help("Glisser pour réordonner")
                        icon(for: item)
                        VStack(alignment: .leading, spacing: 2) {
                            if item.kind == .application, store.application(for: item) == nil {
                                Text("Application indisponible")
                                    .lineLimit(1)
                                Text(item.target)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(item.kind == .application ? (store.application(for: item)?.name ?? item.target) : item.title)
                                    .lineLimit(1)
                            }
                            if item.kind == .website {
                                Text(item.target)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Menu {
                            itemActions(for: item)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Actions pour \(item.title)")
                    }
                    .buttonStyle(.borderless)
                    .tag(item.id)
                    .contextMenu { itemActions(for: item) }
                    .draggable(item.id)
                    .dropDestination(for: String.self) { draggedIDs, location in
                        guard let draggedID = draggedIDs.first,
                              store.items.contains(where: { $0.id == draggedID }) else { return false }
                        store.moveItem(withID: draggedID, relativeTo: item.id, after: location.y > 22)
                        return true
                    } isTargeted: { isTargeted in
                        dropTargetID = isTargeted ? item.id : nil
                    }
                    .background(dropTargetID == item.id ? Color.accentColor.opacity(0.12) : .clear)
                }
                .onMove { offsets, destination in
                    store.moveItems(from: offsets, to: destination)
                }
            }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disposition").font(.headline)
            gridControls
            Divider()
            Text("Apparence").font(.headline)
            displayControls
        }
        .padding(12)
    }

    private var gridControls: some View {
        HStack(spacing: 10) {
            Text("Grille")
                .fixedSize(horizontal: true, vertical: false)

            Picker("Grille", selection: Binding(
                get: { store.gridSettings.mode },
                set: { store.setGridMode($0) }
            )) {
                Text("Automatique").tag(WidgetGridSettings.Mode.automatic)
                Text("Manuelle").tag(WidgetGridSettings.Mode.manual)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 205)

            if store.gridSettings.mode == .manual {
                Stepper(value: Binding(
                    get: { store.gridSettings.manualColumnCount },
                    set: { store.setManualColumnCount($0) }
                ), in: 1...WidgetGridSettings.maximumManualColumns) {
                    Text("\(store.gridSettings.manualColumnCount) colonnes")
                        .monospacedDigit()
                }
                .help("Le widget limite ce nombre aux colonnes disponibles dans son format.")
            } else {
                Text("Adaptée au format, au nombre d’éléments et aux noms affichés")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Afficher les noms", isOn: Binding(
                get: { store.displaySettings.showsNames },
                set: { store.setShowsNames($0) }
            ))
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                Text("Densité")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Densité", selection: Binding(
                    get: { store.displaySettings.density },
                    set: { store.setDensity($0) }
                )) {
                    ForEach(WidgetDisplaySettings.Density.allCases, id: \.self) { density in
                        Text(density.title).tag(density)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private var catalogAndWebsite: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bibliothèque d’applications").font(.headline)
                Spacer()
                Button {
                    Task { await store.refreshApplications() }
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
            .padding(.top, 12)
            HStack(spacing: 4) {
                TextField("Rechercher une application", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                if !search.isEmpty {
                    Button {
                        search = ""
                        searchIsFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Effacer la recherche")
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(searchIsFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: searchIsFocused ? 2 : 0.5)
                    .allowsHitTesting(false)
            }
            Toggle("Afficher les composants auxiliaires", isOn: $showAuxiliaryApplications)
                .font(.caption)
            List(selection: $selectedCatalogIDs) {
                ForEach(filteredApplications) { application in
                    HStack(spacing: 10) {
                    if let iconURL = application.iconURL, let image = IconAssetStore.loadCachedImage(from: iconURL) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app.fill").frame(width: 24, height: 24)
                    }
                    Text(application.name).lineLimit(1)
                    if application.isAuxiliary {
                        Text("Auxiliaire")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.toggle(application)
                    } label: {
                        Image(systemName: store.contains(application) ? "checkmark.circle.fill" : "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(store.contains(application) ? "Retirer du widget" : "Ajouter au widget")
                    }
                    .tag(application.id)
                }
            }
            HStack {
                Text("\(filteredApplications.count) application\(filteredApplications.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ajouter la sélection (\(selectedCatalogAdditions.count))") {
                    store.addApplications(selectedCatalogAdditions)
                    selectedCatalogIDs.removeAll()
                }
                .disabled(selectedCatalogAdditions.isEmpty)
            }
            Divider()
            Text("Ajouter un lien web")
                .font(.headline)
            TextField("Nom du lien", text: $websiteTitle)
            TextField("https://exemple.com", text: $websiteAddress)
            Button("Ajouter le lien") {
                if store.addWebsite(title: websiteTitle, address: websiteAddress) {
                    websiteTitle = ""
                    websiteAddress = ""
                }
            }
            .disabled(websiteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || websiteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var rightPane: some View {
        VStack(spacing: 0) {
            Picker("Panneau", selection: $selectedRightPane) {
                Text("Applications").tag(CompanionRightPane.applications)
                Text("Aperçu").tag(CompanionRightPane.preview)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(12)
            Divider()

            if selectedRightPane == .applications {
                catalogAndWebsite
            } else {
                ScrollView(.vertical) {
                    WidgetPreviewView(store: store)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func icon(for item: LauncherItem) -> some View {
        let iconURL: URL? = if item.kind == .application {
            IconAssetStore.url(for: item.customIconFilename) ?? store.application(for: item)?.iconURL
        } else {
            IconAssetStore.url(for: item.websiteCustomIconFilename) ?? IconAssetStore.url(for: item.websiteIconFilename)
        }
        if let iconURL, let image = IconAssetStore.loadCachedImage(from: iconURL) {
            if item.kind == .website || item.customIconFilename != nil {
                WebsiteIconView(image: image, size: 26)
            } else {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 26, height: 26)
            }
        } else {
            if item.kind == .application, store.application(for: item) == nil {
                Image(systemName: "app.fill")
                    .font(.system(size: 20))
                    .frame(width: 26, height: 26)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.orange, .background)
                            .offset(x: 3, y: 3)
                    }
                    .accessibilityLabel("Application indisponible")
            } else {
                Image(systemName: item.kind == .website ? "globe" : "app.fill")
                    .font(.system(size: 20))
                    .frame(width: 26, height: 26)
            }
        }
    }

    @ViewBuilder
    private func itemActions(for item: LauncherItem) -> some View {
        Button("Déplacer en haut", systemImage: "arrow.up.to.line") {
            store.moveToTop(item)
        }
        .disabled(store.items.first?.id == item.id)
        Button("Monter", systemImage: "arrow.up") {
            store.move(item, by: -1)
        }
        .disabled(store.items.first?.id == item.id)
        Button("Descendre", systemImage: "arrow.down") {
            store.move(item, by: 1)
        }
        .disabled(store.items.last?.id == item.id)
        Button("Retirer", systemImage: "minus.circle", role: .destructive) {
            store.remove(item)
        }
        Divider()
        Menu("Icône") {
            Button {
                iconImportTargetID = item.id
                showingImageImporter = true
            } label: {
                Label("Choisir une image personnalisée…", systemImage: "photo")
            }
            if item.personalIconFilename != nil {
                Button {
                    store.restoreDefaultIcon(for: item.id)
                } label: {
                    Label(item.kind == .application ? "Restaurer l’icône originale" : "Restaurer l’icône du site", systemImage: "arrow.uturn.backward")
                }
            }
            if item.kind == .website {
                Divider()
                Button {
                    store.refreshWebsiteIcon(for: item.id)
                } label: {
                    Label("Récupérer l’icône automatique du site", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

private enum CompanionRightPane: Hashable {
    case applications
    case preview
}
