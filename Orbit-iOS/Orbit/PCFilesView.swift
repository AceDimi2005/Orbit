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
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "music.note" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .script) == true { return "chevron.left.forwardslash.chevron.right" }
        if type?.conforms(to: .executable) == true { return "app" }
        return "doc"
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let regularDateFormatter = ISO8601DateFormatter()

    /// Size and date for files, the date for folders.
    var detail: String {
        var values: [String] = []
        if let sizeBytes, !isDirectory { values.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)) }
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

private struct PCFileResult: Decodable { let ok: Bool; let path: String? }
private struct PCFileNameRequest: Encodable { let parent: String; let name: String }
private struct PCFileRenameRequest: Encodable { let path: String; let name: String }
private struct PCFileMoveRequest: Encodable { let path: String; let destinationDirectory: String }
private struct PCFilePathRequest: Encodable { let path: String }
private struct PCFileFavorite: Codable, Identifiable { let name: String; let path: String; var id: String { path } }
private enum PCFilePrompt: String, Identifiable { case folder, rename, move; var id: String { rawValue } }
private enum PCFileSort: String, CaseIterable {
    case name, size, modified
    var title: String { switch self { case .name: "Name"; case .size: "Size"; case .modified: "Date Modified" } }
}

/// A folder on the PC, pushed onto the Files stack.
private struct PCFolderRoute: Hashable {
    let path: String
}

/// What one folder listing returned, kept per folder so going back shows it at once.
private struct PCFolderListing {
    var entries: [PCFileEntry] = []
    var total = 0
    var truncated = false
    var loaded = false
}

/// The PC's files: drives and quick-access folders first, then folders pushed like the
/// Files app, with the system back button and swipe to go back. Files always use an
/// immutable, pinned HTTPS client for the selected PC; a connection change cancels
/// transfers and discards old results.
struct PCFilesView: View {
    @ObservedObject var vm: OrbitViewModel
    @State private var stack: [PCFolderRoute] = []
    @State private var listings: [String: PCFolderListing] = [:]
    @State private var roots: PCFileRoots?
    @State private var favorites: [PCFileFavorite] = []
    @State private var search = ""
    @State private var sort: PCFileSort = .name
    @State private var selected = Set<String>()
    @State private var selecting = false
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var prompt: PCFilePrompt?
    @State private var promptValue = ""
    @State private var actionEntries: [PCFileEntry] = []
    @State private var confirmTrash = false
    @State private var showImporter = false
    @State private var photos: [PhotosPickerItem] = []
    /// The photo picker is presented from the stack, not from inside a toolbar menu: a picker
    /// living in a Menu is torn down with the menu and never appears.
    @State private var showPhotoPicker = false
    /// Off (default, like iOS's "Transfer to Mac or PC: Automatic"): JPEG and H.264 that open
    /// anywhere on Windows. On: the untouched HEIC/HEVC originals.
    @AppStorage("orbit.files.keepOriginalPhotos") private var keepOriginalPhotos = false
    @AppStorage("orbit.theme") private var theme: OrbitTheme = .noir
    @State private var previewURL: URL?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var transferTask: Task<Void, Never>?
    @State private var transferID = UUID()
    @State private var transferTitle: String?
    @State private var transferProgress: Double = 0
    @State private var transferIndeterminate = false
    @State private var transferPhase = "Encrypted transfer"
    @State private var temporaryFiles: [URL] = []
    @State private var transferTotalBytes: Int64 = 0
    @State private var transferSpeed: Double = 0
    @State private var lastProgressTime = Date()
    @State private var lastProgressBytes: Double = 0
    @State private var refreshID = UUID()

    private var enabled: Bool { vm.metrics.isOnline && !vm.isDemoMode }
    private var favoritesKey: String { "Orbit.Files.Favorites.\(vm.selectedPCStorageKey)" }
    private var currentPath: String? { stack.last?.path }
    private var entries: [PCFileEntry] { listings[listingKey(currentPath, search: search)]?.entries ?? [] }
    private var queryIdentity: String { "\(vm.connectionID)|\(listingKey(currentPath, search: search))|\(refreshID)" }

    private func listingKey(_ path: String?, search: String) -> String { "\(path ?? "")|\(search)|\(sort.rawValue)" }

    var body: some View {
        NavigationStack(path: $stack) {
            locations
                .navigationDestination(for: PCFolderRoute.self) { route in folder(route.path) }
        }
        .safeAreaInset(edge: .bottom) {
            if transferTitle != nil {
                transferCard
                    .padding(.horizontal, OrbitMetrics.gutter)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(OrbitMotion.standard, value: transferTitle != nil)
        .animation(OrbitMotion.standard, value: selecting)
        .task(id: queryIdentity) {
            if !search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            await refresh()
        }
        .onChange(of: stack) { _, _ in
            search = ""; selected = []; selecting = false; error = nil; notice = nil
        }
        .onChange(of: vm.connectionID) { _, _ in resetConnection() }
        .onChange(of: photos) { _, items in uploadPhotos(items) }
        .onDisappear { cancelTransfer(); cleanTemporaryFiles() }
        .onChange(of: previewURL) { before, after in if before != nil && after == nil { cleanTemporaryFiles() } }
        .onChange(of: showShare) { _, visible in if !visible { shareURLs = []; cleanTemporaryFiles() } }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showShare) { PCFileShareSheet(urls: shareURLs) }
        .sheet(item: $prompt) { item in promptSheet(item) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): uploadFiles(urls, securityScoped: true)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photos, maxSelectionCount: 50, selectionBehavior: .ordered,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: keepOriginalPhotos ? .current : .compatible)
        .confirmationDialog("Move to the Recycle Bin?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button(actionEntries.count == 1 ? "Move 1 Item" : "Move \(actionEntries.count) Items", role: .destructive) { recycleSelection() }
            Button("Cancel", role: .cancel) { actionEntries = [] }
        } message: {
            Text("They go to the Windows Recycle Bin, so you can bring them back on the PC. Orbit never deletes files for good.")
        }
    }

    // MARK: Path helpers

    private func folderName(_ path: String) -> String {
        pathComponents(path).last ?? path
    }

    /// The folders above this one, ending with its parent: "C: › Users" for `C:\Users\Dimi`.
    /// Long trails keep their last folders; the back button's menu lists all of them.
    private func trail(_ path: String) -> String {
        let ancestors = pathComponents(path).dropLast()
        guard !ancestors.isEmpty else { return vm.selectedPCName }
        let shown = ancestors.suffix(3).joined(separator: " › ")
        return ancestors.count > 3 ? "… › " + shown : shown
    }

    /// `C:\Users\Dimi` → ["C:", "Users", "Dimi"]; network paths keep their server as the first part.
    private func pathComponents(_ path: String) -> [String] {
        path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: Locations

    private var locations: some View {
        List {
            if !enabled {
                Section {
                    OrbitEmptyMessage(systemImage: "folder", title: vm.isDemoMode ? "Files need your own PC" : "Your PC isn't connected",
                                      message: vm.isDemoMode ? "Connect a PC to browse and send files." : "Wake it or check that Orbit Companion is running, then come back.")
                        .listRowBackground(Color.clear)
                }
            }
            if let error, currentPath == nil {
                Section { OrbitInlineStatus(text: error, kind: .problem) }
            }
            if let roots, enabled {
                if !roots.shortcuts.isEmpty {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 10)], spacing: 10) {
                            ForEach(roots.shortcuts) { location in
                                Button {
                                    OrbitHaptics.tap()
                                    stack.append(PCFolderRoute(path: location.path))
                                } label: {
                                    locationTile(location.name, systemImage: folderIcon(for: location.name))
                                }
                                .buttonStyle(PCTileButtonStyle())
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    } header: {
                        Text("Quick Access")
                    }
                }
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { favorite in
                            NavigationLink(value: PCFolderRoute(path: favorite.path)) {
                                locationRow(favorite.name, detail: favorite.path, systemImage: "star")
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", systemImage: "star.slash", role: .destructive) { removeFavorite(favorite.path) }
                            }
                            .contextMenu {
                                Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) { removeFavorite(favorite.path) }
                            }
                        }
                    }
                }
                Section {
                    ForEach(roots.roots) { location in
                        NavigationLink(value: PCFolderRoute(path: location.path)) {
                            locationRow(location.name, detail: location.kind == "external" ? "Removable drive" : "Drive",
                                        systemImage: location.kind == "external" ? "externaldrive" : "internaldrive")
                        }
                    }
                } header: {
                    Text("Drives")
                } footer: {
                    Text("Files stay on your PC until you open or save them. Transfers are encrypted, and Windows account permissions apply.")
                }
            } else if loading && enabled {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the PC's drives…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .orbitListBackground()
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .tint(.primary)
                    .disabled(!enabled || transferTitle != nil)
            }
        }
        .refreshable { await refresh() }
    }

    private func locationTile(_ name: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(height: 24)
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func locationRow(_ name: String, detail: String?, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail, detail != name {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func folderIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("desktop") { return "menubar.dock.rectangle" }
        if lower.contains("download") { return "arrow.down.circle" }
        if lower.contains("document") { return "doc.text" }
        if lower.contains("picture") || lower.contains("photo") { return "photo" }
        if lower.contains("video") || lower.contains("movie") { return "film" }
        if lower.contains("music") { return "music.note" }
        return "folder"
    }

    // MARK: Folder

    private func folder(_ path: String) -> some View {
        let isCurrent = path == currentPath
        let listing = listings[listingKey(path, search: isCurrent ? search : "")] ?? PCFolderListing()
        return List(selection: $selected) {
            if isCurrent, let error {
                Section { OrbitInlineStatus(text: error, kind: .problem) }
            }
            if isCurrent, let notice {
                Section { OrbitInlineStatus(text: notice, kind: .success) }
            }
            Section {
                ForEach(listing.entries) { entry in fileRow(entry) }
                if listing.entries.isEmpty {
                    if isCurrent && loading || !listing.loaded {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading the folder…")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                    } else {
                        OrbitEmptyMessage(systemImage: isCurrent && !search.isEmpty ? "magnifyingglass" : "folder",
                                          title: isCurrent && !search.isEmpty ? "No matches" : "This folder is empty",
                                          message: isCurrent && !search.isEmpty ? "Try another name." : "Add files with the plus button.")
                            .listRowBackground(Color.clear)
                    }
                }
                if listing.entries.count < listing.total {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack {
                            Text("Show More")
                            Spacer()
                            Text("\(listing.entries.count) of \(listing.total)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .disabled(loading || !isCurrent)
                }
            } header: {
                if !listing.entries.isEmpty {
                    Text(listing.total == 1 ? "1 Item" : "\(listing.total) Items")
                }
            } footer: {
                if listing.truncated {
                    Text("This folder has more than 100,000 items. Search it or open a folder inside it.")
                } else if !listing.entries.isEmpty && !selecting {
                    Text("Swipe right to save a file, left for more.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .orbitListBackground()
        .environment(\.editMode, .constant(selecting && isCurrent ? .active : .inactive))
        .navigationTitle(folderName(path))
        .navigationSubtitle(trail(path))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search this folder")
        .toolbar { folderToolbar(path) }
        .refreshable { await refresh() }
    }

    private func fileRow(_ entry: PCFileEntry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink(value: PCFolderRoute(path: entry.path)) { fileLabel(entry) }
            } else {
                Button {
                    download([entry], preview: entry.canPreview)
                } label: {
                    fileLabel(entry)
                }
                .tint(.primary)
            }
        }
        .tag(entry.path)
        .disabled(!enabled || transferTitle != nil)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(entry.isDirectory ? "Save as ZIP" : "Save", systemImage: "arrow.down.circle") { download([entry], preview: false) }
                .tint(theme.orbitTint)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Recycle", systemImage: "trash", role: .destructive) { actionEntries = [entry]; confirmTrash = true }
            Button("Move", systemImage: "folder") { actionEntries = [entry]; promptValue = ""; prompt = .move }
                .tint(.gray)
            Button("Rename", systemImage: "pencil") { actionEntries = [entry]; promptValue = entry.name; prompt = .rename }
                .tint(.gray)
        }
        .contextMenu { fileActions(entry) }
    }

    private func fileLabel(_ entry: PCFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol)
                .font(.title3)
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !entry.isDirectory && !selecting {
                Image(systemName: entry.canPreview ? "eye" : "arrow.down.circle")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.isDirectory ? "Opens the folder" : (entry.canPreview ? "Opens a preview" : "Saves it to this iPhone"))
    }

    @ViewBuilder private func fileActions(_ entry: PCFileEntry) -> some View {
        if entry.isDirectory {
            Button("Save as ZIP", systemImage: "arrow.down.doc") { download([entry], preview: false) }
            Button(favorites.contains { $0.path == entry.path } ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: favorites.contains { $0.path == entry.path } ? "star.slash" : "star") { toggleFavorite(entry.path) }
        } else {
            if entry.canPreview { Button("Preview", systemImage: "eye") { download([entry], preview: true) } }
            Button("Save to iPhone", systemImage: "square.and.arrow.down") { download([entry], preview: false) }
        }
        Button("Rename", systemImage: "pencil") { actionEntries = [entry]; promptValue = entry.name; prompt = .rename }
        Button("Move", systemImage: "folder") { actionEntries = [entry]; promptValue = ""; prompt = .move }
        Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.path }
        Divider()
        Button("Move to Recycle Bin", systemImage: "trash", role: .destructive) { actionEntries = [entry]; confirmTrash = true }
    }

    @ToolbarContentBuilder
    private func folderToolbar(_ path: String) -> some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    OrbitHaptics.tap()
                    selecting = false
                    selected = []
                }
                .fontWeight(.semibold)
                .tint(.primary)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Save", systemImage: "arrow.down.circle") { download(entries.filter { selected.contains($0.path) }, preview: false) }
                    .disabled(!enabled || transferTitle != nil || !entries.contains { selected.contains($0.path) })
                Spacer()
                Text(selected.count == 1 ? "1 Selected" : "\(selected.count) Selected")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Spacer()
                Menu {
                    Button("Move", systemImage: "folder") { actionEntries = entries.filter { selected.contains($0.path) }; promptValue = ""; prompt = .move }
                    Button("Move to Recycle Bin", systemImage: "trash", role: .destructive) {
                        actionEntries = entries.filter { selected.contains($0.path) }; confirmTrash = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .disabled(!enabled || transferTitle != nil || selected.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Add to \(folderName(path))") {
                        Button("New Folder", systemImage: "folder.badge.plus") { actionEntries = []; promptValue = ""; prompt = .folder }
                        Button("Upload Files", systemImage: "square.and.arrow.up") { showImporter = true }
                        Button("Upload Photos or Videos", systemImage: "photo.on.rectangle.angled") { showPhotoPicker = true }
                    }
                    Picker("Photos and Videos Arrive As", selection: $keepOriginalPhotos) {
                        Text("Most Compatible").tag(false)
                        Text("Originals (HEIC, HEVC)").tag(true)
                    }
                    .pickerStyle(.menu)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .tint(.primary)
                .disabled(!enabled || transferTitle != nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select", systemImage: "checkmark.circle") {
                        OrbitHaptics.tap()
                        selecting = true
                    }
                    Picker("Sort By", selection: $sort) {
                        ForEach(PCFileSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Divider()
                    Button(favorites.contains { $0.path == path } ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: favorites.contains { $0.path == path } ? "star.slash" : "star") {
                        OrbitHaptics.selection()
                        toggleFavorite(path)
                    }
                    Button("Save Folder as ZIP", systemImage: "arrow.down.doc") { download([folderEntry(path)], preview: false) }
                    Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .tint(.primary)
                .disabled(!enabled || transferTitle != nil)
            }
        }
    }

    // MARK: Transfer

    private var transferCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transferTitle ?? "Transfer")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if transferIndeterminate {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(transferPhase)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    OrbitMeter(fraction: transferProgress, style: AnyShapeStyle(.tint))
                    HStack {
                        Text("\(Int(transferProgress * 100))%")
                        Spacer()
                        if transferSpeed > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(transferSpeed), countStyle: .file))/s")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                }
            }
            Button {
                OrbitHaptics.warning()
                cancelTransfer()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel the transfer")
        }
        .padding(16)
        .orbitGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func promptSheet(_ kind: PCFilePrompt) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind == .move ? "D:\\Documents" : "Name", text: $promptValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(kind == .move ? "Destination Folder" : "Name")
                } footer: {
                    if kind == .move {
                        Text(actionEntries.count > 1
                             ? "Type the full path of a folder on the PC. \(actionEntries.count) items move there; nothing is overwritten."
                             : "Type the full path of a folder on the PC. Nothing is overwritten.")
                    }
                }
                if kind == .move {
                    let places = favorites.map { ($0.name, $0.path) } + (roots?.shortcuts.map { ($0.name, $0.path) } ?? [])
                    if !places.isEmpty {
                        Section("Places") {
                            ForEach(places, id: \.1) { name, path in
                                Button {
                                    promptValue = path
                                } label: {
                                    HStack {
                                        Text(name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if promptValue == path {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .orbitListBackground()
            .navigationTitle(kind == .folder ? "New Folder" : kind == .rename ? "Rename" : "Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { prompt = nil }
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { submitPrompt(kind) }
                        .disabled(promptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !enabled)
                }
            }
        }
        .tint(theme.orbitTint)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    // MARK: Loading

    @MainActor private func refresh() async {
        guard enabled else { return }
        let generation = vm.connectionID
        let requestedPath = currentPath
        let requestedSearch = search, requestedSort = sort
        let key = listingKey(requestedPath, search: requestedSearch)
        loading = true
        error = nil
        loadFavorites()
        defer { if vm.connectionID == generation { loading = false } }
        do {
            let client = try vm.companionClient()
            if let requestedPath {
                let page: PCFilePage = try await client.get(path: "/api/files/list", query: ["path": requestedPath, "search": requestedSearch, "sort": requestedSort.rawValue])
                try Task.checkCancellation()
                guard vm.connectionID == generation else { return }
                listings[key] = PCFolderListing(entries: page.entries, total: page.total, truncated: page.truncated == true, loaded: true)
                if currentPath == requestedPath { selected.formIntersection(Set(page.entries.map(\.path))) }
            } else {
                let locations: PCFileRoots = try await client.get(path: "/api/files/roots")
                try Task.checkCancellation()
                guard vm.connectionID == generation else { return }
                roots = locations
            }
        } catch is CancellationError { } catch {
            if vm.connectionID == generation, currentPath == requestedPath { self.error = error.localizedDescription }
        }
    }

    @MainActor private func loadMore() async {
        guard enabled, let path = currentPath, !loading else { return }
        let generation = vm.connectionID
        let requestedSearch = search, requestedSort = sort
        let key = listingKey(path, search: requestedSearch)
        let loaded = listings[key]?.entries.count ?? 0
        loading = true
        defer { if vm.connectionID == generation { loading = false } }
        do {
            let page: PCFilePage = try await vm.companionClient().get(path: "/api/files/list", query: ["path": path, "search": requestedSearch, "sort": requestedSort.rawValue, "offset": String(loaded)])
            guard vm.connectionID == generation && currentPath == path && search == requestedSearch && sort == requestedSort else { return }
            var listing = listings[key] ?? PCFolderListing()
            let previous = Set(listing.entries.map(\.path))
            listing.entries += page.entries.filter { !previous.contains($0.path) }
            listing.total = page.total
            listing.loaded = true
            listings[key] = listing
        } catch { if vm.connectionID == generation { self.error = error.localizedDescription } }
    }

    private func folderEntry(_ path: String) -> PCFileEntry {
        let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "PC files"
        return PCFileEntry(name: name, path: path, isDirectory: true, sizeBytes: nil, modifiedAt: nil, canPreview: false)
    }

    private func resetConnection() {
        cancelTransfer(); roots = nil; stack = []; listings = [:]; favorites = []; selected = []; selecting = false
        actionEntries = []; prompt = nil; confirmTrash = false; previewURL = nil; showShare = false; error = nil; notice = nil; search = ""; loading = false
        loadFavorites()
    }

    // MARK: Favorites

    private func loadFavorites() {
        favorites = UserDefaults.standard.data(forKey: favoritesKey).flatMap { try? JSONDecoder().decode([PCFileFavorite].self, from: $0) } ?? []
    }
    private func saveFavorites() { if let data = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(data, forKey: favoritesKey) } }
    private func removeFavorite(_ path: String) {
        favorites.removeAll { $0.path == path }
        saveFavorites()
    }
    private func toggleFavorite(_ path: String) {
        if favorites.contains(where: { $0.path == path }) { favorites.removeAll { $0.path == path } }
        else {
            let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
            favorites.append(PCFileFavorite(name: name, path: path))
        }
        saveFavorites()
    }

    // MARK: Transfers

    private func cancelTransfer() {
        transferTask?.cancel(); transferTask = nil; transferID = UUID(); transferTitle = nil; transferProgress = 0; transferSpeed = 0; transferIndeterminate = false; transferPhase = "Encrypted transfer"
    }

    private func cleanTemporaryFiles() {
        guard previewURL == nil && !showShare && transferTitle == nil else { return }
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
    }

    private func beginProgress(size: Int64) {
        transferTotalBytes = size; transferSpeed = 0; transferProgress = 0; lastProgressBytes = 0; lastProgressTime = Date()
        transferIndeterminate = false; transferPhase = "Encrypted transfer"
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
            error = "Previews are limited to 64 MB. Save the file to your iPhone instead."
            return
        }
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch { self.error = error.localizedDescription; return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferProgress = 0; transferTitle = "Getting \(items[0].name)"; error = nil; notice = nil
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
                        transferTitle = items.count > 1 ? "Getting \(item.name) · \(index + 1) of \(items.count)" : "Getting \(item.name)"
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
                        notice = "This file is over the 64 MB preview limit, so here are the ways to save it."
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
        transferTitle = count > 1 ? "Packing \(folder.name) · \(index + 1) of \(count)" : "Packing \(folder.name)"
        transferProgress = 0; transferSpeed = 0; transferIndeterminate = true; transferPhase = "Looking through the folder…"
        // An unstructured request can finish returning its job ID after a
        // cancellation, allowing the matching server job to be removed.
        let preparation = Task { () throws -> PCFileArchiveJob in
            try await client.send(path: "/api/files/archive", body: PCFilePathRequest(path: folder.path))
        }
        var job = try await preparation.value
        let jobID = job.id
        guard jobID.count == 32 && jobID.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw NSError(domain: "Orbit.Files", code: 3, userInfo: [NSLocalizedDescriptionKey: "The PC sent back something unexpected. Update Orbit Companion and try again."])
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
                throw NSError(domain: "Orbit.Files", code: 3, userInfo: [NSLocalizedDescriptionKey: "The folder changed while it was being packed. Save it again."])
            }
            if job.status == "ready" { break }
            guard Date() < deadline else {
                throw NSError(domain: "Orbit.Files", code: 4, userInfo: [NSLocalizedDescriptionKey: "This folder takes too long to pack. Try a smaller one."])
            }
            if job.status == "failed" || job.status == "cancelling" {
                throw NSError(domain: "Orbit.Files", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: job.error ?? "Packing the folder stopped. Save it again when you're ready."])
            }
            transferIndeterminate = job.status == "scanning"
            transferProgress = min(1, max(0, job.progress))
            transferPhase = transferIndeterminate ? "Looking through the folder…" : "Packing \(job.totalEntries) items"
            try await Task.sleep(for: .milliseconds(400))
            job = try await client.get(path: "/api/files/archive/\(jobID)")
        }
        beginProgress(size: job.archiveBytes ?? 0)
        transferTitle = count > 1 ? "Getting \(job.name) · \(index + 1) of \(count)" : "Getting \(job.name)"
        return try await client.download(path: "/api/files/archive/\(jobID)/download", query: [:],
                                         progress: progressHandler(identifier, generation: generation))
    }

    private func uploadFiles(_ urls: [URL], securityScoped: Bool, unreadable: Int = 0) {
        guard enabled, let directory = currentPath, !urls.isEmpty, transferTitle == nil else { return }
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch { self.error = error.localizedDescription; return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferTitle = "Getting ready to send…"; transferProgress = 0; error = nil; notice = nil
        transferTask = Task { @MainActor in
            var completed = 0
            var renamed = 0
            defer {
                if !securityScoped {
                    for url in urls {
                        try? FileManager.default.removeItem(at: url)
                        let folder = url.deletingLastPathComponent()
                        if folder.lastPathComponent.hasPrefix("OrbitPhotos-") { try? FileManager.default.removeItem(at: folder) }
                    }
                }
                if transferID == identifier { transferTitle = nil; transferTask = nil; refreshID = UUID() }
            }
            do {
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    guard generation == vm.connectionID else { throw CancellationError() }
                    let access = securityScoped && url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        throw NSError(domain: "Orbit.Files", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose files rather than folders. Folders can't be sent."])
                    }
                    beginProgress(size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                    let name = OrbitFileNames.windowsSafe(url.lastPathComponent) ?? "Upload \(index + 1)"
                    transferTitle = urls.count > 1 ? "Sending \(name) · \(index + 1) of \(urls.count)" : "Sending \(name)"
                    // A name that is already taken on the PC becomes "name (2).ext": nothing is overwritten.
                    let saved = try await client.uploadAvoidingConflicts(directory: directory, name: name, file: url,
                                                                         progress: progressHandler(identifier, generation: generation))
                    if saved != name { renamed += 1 }
                    completed += 1
                }
                if generation == vm.connectionID && transferID == identifier {
                    var parts = [completed == 1 ? "Sent 1 file to \(folderName(directory))." : "Sent \(completed) files to \(folderName(directory))."]
                    if renamed > 0 { parts.append(renamed == 1 ? "1 got a new name because the name was taken." : "\(renamed) got new names because the names were taken.") }
                    if unreadable > 0 { parts.append(unreadable == 1 ? "1 item couldn't be read from Photos." : "\(unreadable) items couldn't be read from Photos.") }
                    notice = parts.joined(separator: " ")
                }
            } catch is CancellationError { } catch {
                if generation == vm.connectionID && transferID == identifier { self.error = "\(completed > 0 ? "Sent \(completed) before this: " : "")\(error.localizedDescription)" }
            }
        }
    }

    private static let photoStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// Items picked in Photos: each one is exported (JPEG / H.264 unless originals are chosen), given a
    /// Windows-safe name and then uploaded exactly like files from the Files app.
    private func uploadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        guard enabled, currentPath != nil, transferTitle == nil else { photos = []; return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferTitle = items.count == 1 ? "Getting 1 item from Photos" : "Getting \(items.count) items from Photos"
        transferProgress = 0; transferSpeed = 0; transferIndeterminate = true
        transferPhase = keepOriginalPhotos ? "Reading the originals…" : "Converting for Windows…"
        error = nil; notice = nil
        let stamp = Self.photoStampFormatter.string(from: Date())
        transferTask = Task { @MainActor in
            var prepared: [URL] = []
            var unreadable = 0
            defer {
                photos = []
                if transferID == identifier { transferTask = nil; transferTitle = nil; transferIndeterminate = false }
            }
            do {
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    guard generation == vm.connectionID, transferID == identifier else { throw CancellationError() }
                    transferPhase = "Item \(index + 1) of \(items.count)"
                    guard let exported = try? await item.loadTransferable(type: PCPhotoTransfer.self) else { unreadable += 1; continue }
                    let name = PCPhotoTransfer.uploadName(for: exported.url, index: index, count: items.count, stamp: stamp)
                    let destination = exported.url.deletingLastPathComponent().appendingPathComponent(name)
                    if destination != exported.url { try FileManager.default.moveItem(at: exported.url, to: destination) }
                    prepared.append(destination)
                }
                try Task.checkCancellation()
                guard generation == vm.connectionID, transferID == identifier else { throw CancellationError() }
                guard !prepared.isEmpty else {
                    throw OrbitError(message: items.count == 1
                                     ? "Photos couldn't hand over this item. If it's in iCloud, check the internet connection and try again."
                                     : "Photos couldn't hand over these items. If they're in iCloud, check the internet connection and try again.")
                }
                temporaryFiles += prepared.map { $0.deletingLastPathComponent() }
                transferTask = nil; transferTitle = nil; transferIndeterminate = false
                uploadFiles(prepared, securityScoped: false, unreadable: unreadable)
            } catch {
                for url in prepared { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                if !(error is CancellationError), generation == vm.connectionID, transferID == identifier { self.error = error.localizedDescription }
            }
        }
    }

    // MARK: Operations

    private func submitPrompt(_ kind: PCFilePrompt) {
        let value = promptValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = actionEntries
        let directory = currentPath
        prompt = nil
        performOperation(title: kind == .folder ? "Making the folder…" : kind == .rename ? "Renaming…" : "Moving…",
                         done: kind == .folder ? "Made the folder." : kind == .rename ? "Renamed." : "Moved.") { client in
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
        performOperation(title: "Moving to the Recycle Bin…", done: "Moved to the Recycle Bin.") { client in
            for item in targets {
                try Task.checkCancellation()
                let _: PCFileResult = try await client.send(path: "/api/files/trash", body: PCFilePathRequest(path: item.path))
            }
        }
    }

    private func performOperation(title: String, done: String, work: @escaping (OrbitAPIClient) async throws -> Void) {
        guard enabled, transferTitle == nil else { return }
        let client: OrbitAPIClient
        do { client = try vm.companionClient() } catch { self.error = error.localizedDescription; return }
        let generation = vm.connectionID
        let identifier = UUID(); transferID = identifier
        transferTitle = title; transferProgress = 0; transferIndeterminate = true; transferPhase = "On your PC"; error = nil; notice = nil
        transferTask = Task { @MainActor in
            defer {
                if transferID == identifier {
                    transferTitle = nil; transferTask = nil; transferIndeterminate = false
                    selected = []; selecting = false; actionEntries = []; refreshID = UUID()
                }
            }
            do {
                try Task.checkCancellation()
                guard generation == vm.connectionID else { throw CancellationError() }
                try await work(client)
                guard generation == vm.connectionID && transferID == identifier else { return }
                notice = done
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

/// One item exported from the Photos picker into its own temporary folder. Videos are matched first,
/// so a Live Photo arrives as its still image rather than as a bundle.
private struct PCPhotoTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try store(received.file) }
        FileRepresentation(importedContentType: .image) { received in try store(received.file) }
    }

    private static func store(_ file: URL) throws -> PCPhotoTransfer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitPhotos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(file.lastPathComponent.isEmpty ? "item" : file.lastPathComponent)
        do { try FileManager.default.moveItem(at: file, to: destination) } catch { try FileManager.default.copyItem(at: file, to: destination) }
        return PCPhotoTransfer(url: destination)
    }

    /// Keeps a meaningful original name ("IMG_1234.JPG") with Windows-invalid characters replaced; a
    /// generated or empty one becomes "Photo 2026-10-21 19.41.12.jpg", numbered when several were picked.
    static func uploadName(for file: URL, index: Int, count: Int, stamp: String) -> String {
        let ext = file.pathExtension
        let base = file.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: ext)
        let generic = base.isEmpty || ext.isEmpty || base.hasPrefix("public.") || base.contains("=")
            || UUID(uuidString: base) != nil || base.count > 120
        let kind = type?.conforms(to: .movie) == true ? "Video" : "Photo"
        let fallback = "\(kind) \(stamp)\(count > 1 ? " \(index + 1)" : "")" + (ext.isEmpty ? "" : ".\(ext)")
        return OrbitFileNames.windowsSafe(generic ? fallback : file.lastPathComponent) ?? fallback
    }
}
