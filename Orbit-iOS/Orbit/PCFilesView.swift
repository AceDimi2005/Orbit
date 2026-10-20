import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

private let pcFilePreviewLimit: Int64 = 64 * 1024 * 1024

private struct PCFileLocation: Decodable, Identifiable {
    let name: String
    let path: String
    let kind: String
    var id: String { path }
}

private struct PCFileRoots: Decodable {
    let roots: [PCFileLocation]
    let shortcuts: [PCFileLocation]
}

private struct PCFileEntry: Decodable, Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64?
    let modifiedAt: String?
    let canPreview: Bool
    var id: String { path }
    var symbol: String {
        if isDirectory { return "folder.fill" }
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo.fill" }
        if type?.conforms(to: .movie) == true { return "film.fill" }
        if type?.conforms(to: .audio) == true { return "music.note" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext.fill" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .script) == true { return "chevron.left.forwardslash.chevron.right" }
        if type?.conforms(to: .executable) == true { return "app.badge" }
        return "doc.fill"
    }
    var tint: Color {
        if isDirectory { return .cyan }
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return .pink }
        if type?.conforms(to: .movie) == true { return .purple }
        if type?.conforms(to: .audio) == true { return .orange }
        if type?.conforms(to: .pdf) == true { return .red }
        if type?.conforms(to: .archive) == true { return .yellow }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .script) == true { return .mint }
        if type?.conforms(to: .executable) == true { return .green }
        return .secondary
    }
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let regularDateFormatter = ISO8601DateFormatter()
    var detail: String {
        var values: [String] = isDirectory ? ["Folder"] : []
        if let sizeBytes { values.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)) }
        if let modifiedAt, let date = Self.fractionalDateFormatter.date(from: modifiedAt) ?? Self.regularDateFormatter.date(from: modifiedAt) {
            values.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return values.joined(separator: " · ")
    }
}

private struct PCFilePage: Decodable {
    let path: String
    let parentPath: String?
    let entries: [PCFileEntry]
    let total: Int
    let offset: Int
    let limit: Int
    let truncated: Bool?
}

private struct PCFileArchiveJob: Decodable {
    let id: String
    let name: String
    let status: String
    let progress: Double
    let totalBytes: Int64
    let totalEntries: Int
    let archiveBytes: Int64?
    let error: String?
}

private struct PCFileNavigationLocation {
    let path: String?
    let search: String
    let sort: PCFileSort
}

private struct PCFileResult: Decodable { let ok: Bool; let path: String? }
private struct PCFileNameRequest: Encodable { let parent: String; let name: String }
private struct PCFileRenameRequest: Encodable { let path: String; let name: String }
private struct PCFileMoveRequest: Encodable { let path: String; let destinationDirectory: String }
private struct PCFilePathRequest: Encodable { let path: String }
private struct PCFileFavorite: Codable, Identifiable { let name: String; let path: String; var id: String { path } }
private enum PCFilePrompt: String, Identifiable { case folder, rename, move; var id: String { rawValue } }
private enum PCFileSort: String, CaseIterable { case name, size, modified; var title: String { switch self { case .name: "Name"; case .size: "Size"; case .modified: "Date modified" } } }

/// Files always use an immutable, pinned HTTPS client for the selected PC.
/// A connection generation change cancels transfers and discards old results.
struct PCFilesView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var roots: PCFileRoots?
    @State private var currentPath: String?
    @State private var parentPath: String?
    @State private var backHistory: [PCFileNavigationLocation] = []
    @State private var forwardHistory: [PCFileNavigationLocation] = []
    @State private var entries: [PCFileEntry] = []
    @State private var favorites: [PCFileFavorite] = []
    @State private var search = ""
    @State private var sort: PCFileSort = .name
    @State private var selected = Set<String>()
    @State private var selecting = false
    @State private var loading = false
    @State private var total = 0
    @State private var truncated = false
    @State private var error: String?
    @State private var notice: String?
    @State private var prompt: PCFilePrompt?
    @State private var promptValue = ""
    @State private var actionEntries: [PCFileEntry] = []
    @State private var confirmTrash = false
    @State private var showImporter = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var previewURL: URL?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var transferTask: Task<Void, Never>?
    @State private var transferID = UUID()
    @State private var transferTitle: String?
    @State private var transferProgress: Double = 0
    @State private var transferIndeterminate = false
    @State private var transferPhase = "encrypted transfer"
    @State private var temporaryFiles: [URL] = []
    @State private var transferTotalBytes: Int64 = 0
    @State private var transferSpeed: Double = 0
    @State private var lastProgressTime = Date()
    @State private var lastProgressBytes: Double = 0
    @State private var refreshID = UUID()
    private var enabled: Bool { vm.metrics.isOnline && !vm.isDemoMode }
    private var favoritesKey: String { "Orbit.Files.Favorites.\(vm.selectedPCStorageKey)" }
    private var queryIdentity: String { "\(vm.connectionID)|\(currentPath ?? "")|\(search)|\(sort.rawValue)|\(refreshID)" }

    @Environment(\.orbitTheme) private var theme

    var body: some View {
        List {
            if !enabled {
                Section {
                    OrbitEmptyState(icon: "folder.badge.questionmark", title: "Your PC files",
                                    message: vm.isDemoMode ? "Connect to your own PC to browse and transfer files." : "Keep your PC and Orbit Agent running, then connect to it.",
                                    tint: .blue)
                }
                .orbitRow()
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    .orbitRow(tint: .orange)
            }
            if let notice { Section { Label(notice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.mint) }.orbitRow(tint: .mint) }
            Section { navigationControls }.orbitRow()
            if transferTitle != nil { transferSection.orbitRow(tint: theme.accent) }
            if let currentPath { folderSection(currentPath) } else { locationsSection }
        }
        .orbitListChrome(isOnline: vm.metrics.isOnline)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search this folder")
        .toolbar { fileToolbar }
        .task(id: queryIdentity) {
            if !search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            await refresh()
        }
        .onChange(of: vm.connectionID) { _, _ in resetConnection() }
        .onChange(of: photos) { _, items in uploadPhotos(items) }
        .onDisappear { cancelTransfer(); cleanTemporaryFiles() }
        .onChange(of: previewURL) { before, after in if before != nil && after == nil { cleanTemporaryFiles() } }
        .onChange(of: showShare) { _, visible in if !visible { shareURLs = []; cleanTemporaryFiles() } }
        .refreshable { await refresh() }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showShare) { PCFileShareSheet(urls: shareURLs) }
        .sheet(item: $prompt) { item in promptSheet(item) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): uploadFiles(urls, securityScoped: true)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .confirmationDialog("Move to Recycle Bin?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Recycle \(actionEntries.count) item\(actionEntries.count == 1 ? "" : "s")", role: .destructive) { recycleSelection() }
            Button("Cancel", role: .cancel) { actionEntries = [] }
        } message: { Text("The selected items will be moved to the Windows Recycle Bin. Orbit never permanently deletes them.") }
    }

    private var navigationControls: some View {
        HStack(spacing: 8) {
            navButton("arrow.left", label: "Back", enabled: !backHistory.isEmpty) { goBack() }
            navButton("arrow.right", label: "Forward", enabled: !forwardHistory.isEmpty) { goForward() }
            navButton("arrow.up", label: "Parent folder", enabled: parentPath != nil) { if let parentPath { open(parentPath) } }
            Spacer(minLength: 4)
            Text(currentPath.map { ($0 as NSString).lastPathComponent.isEmpty ? $0 : ($0 as NSString).lastPathComponent } ?? "All locations")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            navButton("house.fill", label: "All locations", enabled: currentPath != nil) { open(nil) }
        }
        .frame(minHeight: 30)
    }

    private func navButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            OrbitHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || !self.enabled || transferTitle != nil)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var locationsSection: some View {
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { favorite in
                    Button { open(favorite.path) } label: {
                        locationLabel(favorite.name, detail: favorite.path, icon: "star.fill", tint: .yellow)
                    }
                    .contextMenu { Button("Remove favorite", role: .destructive) { favorites.removeAll { $0.id == favorite.id }; saveFavorites() } }
                }
            }
            .orbitRow(tint: .yellow)
        }
        if let roots {
            if !roots.shortcuts.isEmpty {
                Section("Quick access") {
                    ForEach(roots.shortcuts) { location in locationButton(location) }
                }
                .orbitRow()
            }
            Section("Drives") { ForEach(roots.roots) { location in locationButton(location) } }
                .orbitRow()
            Section {
                Label("Files stay on your PC until you open or download them. Transfers use your trusted encrypted connection.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .orbitRow()
        } else if loading {
            Section { HStack { ProgressView(); Text("Reading PC locations…") } }.orbitRow()
        }
    }

    private func locationLabel(_ name: String, detail: String?, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            OrbitIconBadge(systemName: icon, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary)
                if let detail, detail != name {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func locationButton(_ location: PCFileLocation) -> some View {
        let icon = location.kind == "shortcut" ? folderIcon(for: location.name) : location.kind == "external" ? "externaldrive.fill" : "internaldrive.fill"
        let tint: Color = location.kind == "shortcut" ? theme.accent : location.kind == "external" ? .orange : .blue
        return Button { open(location.path) } label: {
            locationLabel(location.name, detail: location.path, icon: icon, tint: tint)
        }.disabled(!enabled)
    }

    private func folderIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("desktop") { return "menubar.dock.rectangle" }
        if lower.contains("download") { return "arrow.down.circle.fill" }
        if lower.contains("document") { return "doc.text.fill" }
        if lower.contains("picture") || lower.contains("photo") { return "photo.fill" }
        if lower.contains("video") || lower.contains("movie") { return "film.fill" }
        if lower.contains("music") { return "music.note" }
        return "folder.fill"
    }

    @ViewBuilder private func folderSection(_ path: String) -> some View {
        Section {
            HStack(spacing: 10) {
                OrbitIconBadge(systemName: "folder.fill", tint: theme.accent, size: 30)
                Text(path).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    OrbitHaptics.selection()
                    toggleFavorite(path)
                } label: {
                    Image(systemName: favorites.contains { $0.path == path } ? "star.fill" : "star")
                        .foregroundStyle(favorites.contains { $0.path == path } ? .yellow : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel("Favorite folder")
            }.buttonStyle(.borderless)
            if !selecting {
                Button { download([folderEntry(path)], preview: false) } label: {
                    Label("Download this folder as ZIP", systemImage: "arrow.down.doc")
                }.font(.subheadline).disabled(!enabled || transferTitle != nil)
            }
            if selecting {
                HStack {
                    Text("\(selected.count) selected").font(.caption)
                    Spacer()
                    Button("Select loaded") { selected = Set(entries.map(\.path)) }
                    Button("Clear") { selected = [] }
                }.font(.caption)
            }
        }
        .orbitRow(tint: theme.accent)
        Section {
            ForEach(entries) { entry in fileRow(entry) }
            if loading { HStack { Spacer(); ProgressView(); Spacer() } }
            if !loading && entries.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Empty folder" : "No matching files", systemImage: search.isEmpty ? "folder" : "magnifyingglass")
            }
            if entries.count < total {
                Button("Load more · \(entries.count) of \(total)") { Task { await loadMore() } }.disabled(loading)
            }
        } footer: {
            Text(truncated ? "This folder has more than 100,000 entries. Narrow your search or open a subfolder." : "\(total) item\(total == 1 ? "" : "s") · Windows account permissions apply")
        }
        .orbitRow()
    }

    private func fileRow(_ entry: PCFileEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                if selecting {
                    if selected.contains(entry.path) { selected.remove(entry.path) } else { selected.insert(entry.path) }
                } else if entry.isDirectory { open(entry.path) } else { download([entry], preview: entry.canPreview) }
            } label: {
                HStack(spacing: 12) {
                    if selecting { Image(systemName: selected.contains(entry.path) ? "checkmark.circle.fill" : "circle").foregroundStyle(theme.accent) }
                    OrbitIconBadge(systemName: entry.symbol, tint: entry.isDirectory ? theme.accent : entry.tint, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                        if !entry.detail.isEmpty { Text(entry.detail).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: entry.isDirectory ? "chevron.right" : entry.canPreview ? "eye" : "arrow.down.circle")
                        .font(.caption).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !selecting {
                Menu { fileActions(entry) } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 32, minHeight: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Actions for \(entry.name)")
            }
        }
        .padding(.vertical, 3)
        .disabled(!enabled || transferTitle != nil)
        .contextMenu { fileActions(entry) }
    }

    @ViewBuilder private func fileActions(_ entry: PCFileEntry) -> some View {
        if entry.isDirectory {
            Button("Download folder as ZIP", systemImage: "arrow.down.doc") { download([entry], preview: false) }
            Button("Favorite", systemImage: "star") { toggleFavorite(entry.path) }
        } else {
            if entry.canPreview { Button("Preview", systemImage: "eye") { download([entry], preview: true) } }
            Button("Download / Save to Files", systemImage: "square.and.arrow.down") { download([entry], preview: false) }
        }
        Button("Rename", systemImage: "pencil") { actionEntries = [entry]; promptValue = entry.name; prompt = .rename }
        Button("Move", systemImage: "folder") { actionEntries = [entry]; promptValue = ""; prompt = .move }
        Button("Recycle", systemImage: "trash", role: .destructive) { actionEntries = [entry]; confirmTrash = true }
    }

    @ToolbarContentBuilder private var fileToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if currentPath != nil {
                Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }.disabled(!enabled)
            }
            Menu {
                Picker("Sort by", selection: $sort) { ForEach(PCFileSort.allCases, id: \.self) { Text($0.title).tag($0) } }
                if currentPath != nil {
                    Button("Download this folder as ZIP", systemImage: "arrow.down.doc") {
                        if let currentPath { download([folderEntry(currentPath)], preview: false) }
                    }
                    Button("New folder", systemImage: "folder.badge.plus") { actionEntries = []; promptValue = ""; prompt = .folder }
                    Button("Upload from Files", systemImage: "square.and.arrow.up") { showImporter = true }
                    PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                        Label("Upload photos or videos", systemImage: "photo")
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
            } label: { Image(systemName: "ellipsis.circle") }.disabled(!enabled || transferTitle != nil)
        }
        if selecting && !selected.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Download", systemImage: "arrow.down.circle") { download(entries.filter { selected.contains($0.path) }, preview: false) }
                    .disabled(!enabled || transferTitle != nil || !entries.contains { selected.contains($0.path) })
                Spacer()
                Button("Move", systemImage: "folder") { actionEntries = entries.filter { selected.contains($0.path) }; promptValue = ""; prompt = .move }
                    .disabled(!enabled || transferTitle != nil)
                Spacer()
                Button("Recycle", systemImage: "trash", role: .destructive) { actionEntries = entries.filter { selected.contains($0.path) }; confirmTrash = true }
                    .disabled(!enabled || transferTitle != nil)
            }
        }
    }

    private var transferSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    OrbitRingGauge(progress: transferIndeterminate ? nil : transferProgress, lineWidth: 4, tint: theme.accent)
                        .frame(width: 44, height: 44)
                    if transferIndeterminate {
                        ProgressView().controlSize(.small).tint(theme.accent)
                    } else {
                        Text("\(Int(transferProgress * 100))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(transferTitle ?? "Transfer").font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack {
                        Text(transferIndeterminate ? transferPhase : "\(Int(transferProgress * 100))% · \(transferPhase)")
                        Spacer()
                        if transferSpeed > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(transferSpeed), countStyle: .file))/s").monospacedDigit() }
                    }.font(.caption).foregroundStyle(.secondary)
                    if !transferIndeterminate {
                        ProgressView(value: transferProgress).tint(theme.accent)
                    }
                }
                Button {
                    OrbitHaptics.warning()
                    cancelTransfer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel transfer")
            }
            .padding(.vertical, 4)
        }
    }

    private func promptSheet(_ kind: PCFilePrompt) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind == .move ? "Destination folder, e.g. D:\\Documents" : "Name", text: $promptValue)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if kind == .move {
                        Text("Enter the full path of an existing folder on your PC.").font(.caption).foregroundStyle(.secondary)
                        if !favorites.isEmpty {
                            ForEach(favorites) { favorite in Button(favorite.name) { promptValue = favorite.path } }
                        }
                        if let roots {
                            ForEach(roots.shortcuts) { location in Button(location.name) { promptValue = location.path } }
                        }
                    }
                }
                if kind == .move && actionEntries.count > 1 {
                    Text("\(actionEntries.count) items will be moved. Existing files are never overwritten.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .orbitListChrome()
            .navigationTitle(kind == .folder ? "New folder" : kind == .rename ? "Rename" : "Move items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { prompt = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kind == .folder ? "Create" : kind == .rename ? "Rename" : "Move") { submitPrompt(kind) }
                        .disabled(promptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !enabled)
                }
            }
        }
        .orbitAppearance()
        .presentationDetents([.medium, .large])
    }

    @MainActor private func refresh() async {
        guard enabled else { return }
        let generation = vm.connectionID
        let requestedPath = currentPath
        loading = true
        error = nil
        loadFavorites()
        defer { if vm.connectionID == generation { loading = false } }
        do {
            let client = try vm.companionClient()
            if let requestedPath {
                let page: PCFilePage = try await client.get(path: "/api/files/list", query: ["path": requestedPath, "search": search, "sort": sort.rawValue])
                try Task.checkCancellation()
                guard vm.connectionID == generation && currentPath == requestedPath else { return }
                entries = page.entries; parentPath = page.parentPath; total = page.total; truncated = page.truncated == true
                selected.formIntersection(Set(entries.map(\.path)))
            } else {
                let locations: PCFileRoots = try await client.get(path: "/api/files/roots")
                try Task.checkCancellation()
                guard vm.connectionID == generation && currentPath == nil else { return }
                roots = locations
            }
        } catch is CancellationError { } catch {
            if vm.connectionID == generation { self.error = error.localizedDescription }
        }
    }

    @MainActor private func loadMore() async {
        guard enabled, let path = currentPath, !loading else { return }
        let generation = vm.connectionID
        let requestedSearch = search, requestedSort = sort
        loading = true
        defer { if vm.connectionID == generation { loading = false } }
        do {
            let page: PCFilePage = try await vm.companionClient().get(path: "/api/files/list", query: ["path": path, "search": search, "sort": sort.rawValue, "offset": String(entries.count)])
            guard vm.connectionID == generation && currentPath == path && search == requestedSearch && sort == requestedSort else { return }
            let previous = Set(entries.map(\.path))
            entries += page.entries.filter { !previous.contains($0.path) }
            total = page.total
        } catch { if vm.connectionID == generation { self.error = error.localizedDescription } }
    }

    private var navigationLocation: PCFileNavigationLocation {
        PCFileNavigationLocation(path: currentPath, search: search, sort: sort)
    }

    private func open(_ path: String?) {
        guard currentPath != path else { return }
        backHistory.append(navigationLocation)
        if backHistory.count > 100 { backHistory.removeFirst() }
        forwardHistory = []
        restoreLocation(PCFileNavigationLocation(path: path, search: "", sort: sort))
    }

    private func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(navigationLocation)
        restoreLocation(previous)
    }

    private func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(navigationLocation)
        restoreLocation(next)
    }

    private func restoreLocation(_ location: PCFileNavigationLocation) {
        currentPath = location.path; search = location.search; sort = location.sort
        parentPath = nil; entries = []; total = 0; selected = []; selecting = false; error = nil; notice = nil
    }

    private func folderEntry(_ path: String) -> PCFileEntry {
        let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "PC files"
        return PCFileEntry(name: name, path: path, isDirectory: true, sizeBytes: nil, modifiedAt: nil, canPreview: false)
    }

    private func resetConnection() {
        cancelTransfer(); roots = nil; currentPath = nil; parentPath = nil; backHistory = []; forwardHistory = []; entries = []; favorites = []; selected = []; selecting = false
        actionEntries = []; prompt = nil; confirmTrash = false; previewURL = nil; showShare = false; error = nil; notice = nil; search = ""; loading = false
        loadFavorites()
    }

    private func loadFavorites() {
        favorites = UserDefaults.standard.data(forKey: favoritesKey).flatMap { try? JSONDecoder().decode([PCFileFavorite].self, from: $0) } ?? []
    }
    private func saveFavorites() { if let data = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(data, forKey: favoritesKey) } }
    private func toggleFavorite(_ path: String) {
        if favorites.contains(where: { $0.path == path }) { favorites.removeAll { $0.path == path } }
        else {
            let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
            favorites.append(PCFileFavorite(name: name, path: path))
        }
        saveFavorites()
    }

    private func cancelTransfer() {
        transferTask?.cancel(); transferTask = nil; transferID = UUID(); transferTitle = nil; transferProgress = 0; transferSpeed = 0; transferIndeterminate = false; transferPhase = "encrypted transfer"
    }

    private func cleanTemporaryFiles() {
        guard previewURL == nil && !showShare && transferTitle == nil else { return }
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
    }

    private func beginProgress(size: Int64) {
        transferTotalBytes = size; transferSpeed = 0; transferProgress = 0; lastProgressBytes = 0; lastProgressTime = Date()
        transferIndeterminate = false; transferPhase = "encrypted transfer"
    }

    private func progressHandler(_ identifier: UUID, generation: Int) -> @Sendable (Double) -> Void {
        { progress in Task { @MainActor in
            guard transferID == identifier && vm.connectionID == generation else { return }
            transferProgress = min(1, max(0, progress))
            let elapsed = Date().timeIntervalSince(lastProgressTime)
            if elapsed >= 0.25 {
                let bytes = Double(transferTotalBytes) * transferProgress
                transferSpeed = max(0, (bytes - lastProgressBytes) / elapsed)
                lastProgressBytes = bytes; lastProgressTime = Date()
            }
        } }
    }

    private func download(_ items: [PCFileEntry], preview: Bool) {
        guard enabled, !items.isEmpty, transferTitle == nil else { return }
        if preview && items.contains(where: { ($0.sizeBytes ?? Int64.max) > pcFilePreviewLimit }) {
            error = "Preview is limited to 64 MB per file. Choose Download / Save to Files for larger files."
            return
        }
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch { self.error = error.localizedDescription; return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferProgress = 0; transferTitle = "Downloading \(items[0].name)"; error = nil; notice = nil
        transferTask = Task { @MainActor in
            defer { if transferID == identifier { transferTitle = nil; transferTask = nil } }
            var downloads: [URL] = []
            do {
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    guard generation == vm.connectionID else { throw CancellationError() }
                    let url: URL
                    if item.isDirectory {
                        url = try await downloadArchive(item, index: index, count: items.count, client: client, identifier: identifier, generation: generation)
                    } else {
                        beginProgress(size: item.sizeBytes ?? 0)
                        transferTitle = "Downloading \(item.name) · \(index + 1)/\(items.count)"
                        url = try await client.download(path: "/api/files/download", query: ["path": item.path], progress: progressHandler(identifier, generation: generation))
                    }
                    downloads.append(url)
                    temporaryFiles.append(url)
                }
                try Task.checkCancellation()
                guard generation == vm.connectionID && transferID == identifier else { return }
                if preview, let first = downloads.first {
                    // The PC file may have grown after its directory metadata
                    // was read. Verify the local payload before Quick Look.
                    let downloadedSize = try first.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    if let downloadedSize, Int64(downloadedSize) <= pcFilePreviewLimit {
                        previewURL = first
                    } else {
                        notice = "This file exceeds the 64 MB preview limit. Save or share it instead."
                        shareURLs = downloads; showShare = true
                    }
                } else { shareURLs = downloads; showShare = true }
                selected = []; selecting = false
            } catch is CancellationError {
                for url in downloads { try? FileManager.default.removeItem(at: url) }
            } catch {
                if generation == vm.connectionID && transferID == identifier { self.error = error.localizedDescription }
            }
        }
    }

    @MainActor private func downloadArchive(_ folder: PCFileEntry, index: Int, count: Int, client: OrbitAPIClient,
                                           identifier: UUID, generation: Int) async throws -> URL {
        transferTitle = "Preparing \(folder.name).zip · \(index + 1)/\(count)"
        transferProgress = 0; transferSpeed = 0; transferIndeterminate = true; transferPhase = "Checking folder contents…"
        // An unstructured request can finish returning its job ID after a
        // cancellation, allowing the matching server job to be removed.
        let preparation = Task { () throws -> PCFileArchiveJob in
            try await client.send(path: "/api/files/archive", body: PCFilePathRequest(path: folder.path))
        }
        var job = try await preparation.value
        let jobID = job.id
        guard jobID.count == 32 && jobID.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw NSError(domain: "Orbit.Files", code: 3, userInfo: [NSLocalizedDescriptionKey: "The PC returned an invalid folder transfer. Update Orbit Agent and try again."])
        }
        defer {
            let path = "/api/files/archive/\(jobID)"
            Task { _ = try? await client.data(path, method: "DELETE") }
        }
        let deadline = Date().addingTimeInterval(150)
        while true {
            try Task.checkCancellation()
            guard generation == vm.connectionID && identifier == transferID else { throw CancellationError() }
            guard job.id == jobID else {
                throw NSError(domain: "Orbit.Files", code: 3, userInfo: [NSLocalizedDescriptionKey: "The folder transfer changed unexpectedly. Start the download again."])
            }
            if job.status == "ready" { break }
            guard Date() < deadline else {
                throw NSError(domain: "Orbit.Files", code: 4, userInfo: [NSLocalizedDescriptionKey: "This folder is taking too long to prepare. Choose a smaller folder and try again."])
            }
            if job.status == "failed" || job.status == "cancelling" {
                throw NSError(domain: "Orbit.Files", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: job.error ?? "Folder download was cancelled. Start it again when ready."])
            }
            transferIndeterminate = job.status == "scanning"
            transferProgress = min(1, max(0, job.progress))
            transferPhase = transferIndeterminate ? "Checking folder contents…" : "preparing ZIP · \(job.totalEntries) items"
            try await Task.sleep(for: .milliseconds(400))
            job = try await client.get(path: "/api/files/archive/\(jobID)")
        }
        beginProgress(size: job.archiveBytes ?? 0)
        transferTitle = "Downloading \(job.name) · \(index + 1)/\(count)"
        return try await client.download(path: "/api/files/archive/\(jobID)/download", query: [:],
                                         progress: progressHandler(identifier, generation: generation))
    }

    private func uploadFiles(_ urls: [URL], securityScoped: Bool) {
        guard enabled, let directory = currentPath, !urls.isEmpty, transferTitle == nil else { return }
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch { self.error = error.localizedDescription; return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferTitle = "Preparing upload…"; transferProgress = 0; error = nil; notice = nil
        transferTask = Task { @MainActor in
            var completed = 0
            defer {
                if !securityScoped { for url in urls { try? FileManager.default.removeItem(at: url) } }
                if transferID == identifier { transferTitle = nil; transferTask = nil; refreshID = UUID() }
            }
            do {
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    guard generation == vm.connectionID else { throw CancellationError() }
                    let access = securityScoped && url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        throw NSError(domain: "Orbit.Files", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select files rather than folders. Folder uploads are not supported."])
                    }
                    beginProgress(size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                    transferTitle = "Uploading \(url.lastPathComponent) · \(index + 1)/\(urls.count)"
                    _ = try await client.upload(path: "/api/files/upload", query: ["directory": directory, "name": url.lastPathComponent], file: url, progress: progressHandler(identifier, generation: generation))
                    completed += 1
                }
                if generation == vm.connectionID && transferID == identifier { notice = "Uploaded \(completed) file\(completed == 1 ? "" : "s")." }
            } catch is CancellationError { } catch {
                if generation == vm.connectionID && transferID == identifier { self.error = "\(completed > 0 ? "\(completed) file(s) uploaded. " : "")\(error.localizedDescription)" }
            }
        }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) {
        guard enabled, !items.isEmpty, transferTitle == nil else { return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferTitle = "Preparing photos…"; transferProgress = 0; error = nil
        transferTask = Task { @MainActor in
            var prepared: [URL] = []
            defer { if generation == vm.connectionID { photos = [] }; if transferID == identifier { transferTask = nil; transferTitle = nil } }
            do {
                for item in items {
                    try Task.checkCancellation()
                    guard generation == vm.connectionID else { throw CancellationError() }
                    if let transfer = try await item.loadTransferable(type: PCPhotoTransfer.self) { prepared.append(transfer.url) }
                }
                guard generation == vm.connectionID && transferID == identifier else { throw CancellationError() }
                temporaryFiles += prepared
                transferTask = nil; transferTitle = nil
                uploadFiles(prepared, securityScoped: false)
            } catch is CancellationError { for url in prepared { try? FileManager.default.removeItem(at: url) } }
            catch { if generation == vm.connectionID && transferID == identifier { self.error = error.localizedDescription } }
        }
    }

    private func submitPrompt(_ kind: PCFilePrompt) {
        let value = promptValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = actionEntries
        let directory = currentPath
        prompt = nil
        performOperation(title: kind == .folder ? "Creating folder…" : kind == .rename ? "Renaming…" : "Moving items…") { client in
            if kind == .folder, let directory {
                let _: PCFileResult = try await client.send(path: "/api/files/mkdir", body: PCFileNameRequest(parent: directory, name: value))
            } else if kind == .rename, let item = targets.first {
                let _: PCFileResult = try await client.send(path: "/api/files/rename", body: PCFileRenameRequest(path: item.path, name: value))
            } else if kind == .move {
                for item in targets {
                    try Task.checkCancellation()
                    let _: PCFileResult = try await client.send(path: "/api/files/move", body: PCFileMoveRequest(path: item.path, destinationDirectory: value))
                }
            }
        }
    }

    private func recycleSelection() {
        let targets = actionEntries
        performOperation(title: "Moving to Recycle Bin…") { client in
            for item in targets {
                try Task.checkCancellation()
                let _: PCFileResult = try await client.send(path: "/api/files/trash", body: PCFilePathRequest(path: item.path))
            }
        }
    }

    private func performOperation(title: String, work: @escaping (OrbitAPIClient) async throws -> Void) {
        guard enabled, transferTitle == nil else { return }
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch { self.error = error.localizedDescription; return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferTitle = title; transferProgress = 0; error = nil; notice = nil
        transferTask = Task { @MainActor in
            defer {
                if transferID == identifier { transferTitle = nil; transferTask = nil; selected = []; selecting = false; actionEntries = []; refreshID = UUID() }
            }
            do {
                try Task.checkCancellation()
                guard generation == vm.connectionID else { throw CancellationError() }
                try await work(client)
                guard generation == vm.connectionID && transferID == identifier else { return }
                notice = "Operation completed."
            } catch is CancellationError { } catch {
                if generation == vm.connectionID && transferID == identifier { self.error = error.localizedDescription }
            }
        }
    }
}

private struct PCFileShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct PCPhotoTransfer: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitPhotos-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PCPhotoTransfer(url: destination)
        }
    }
}
