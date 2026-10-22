import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style browser for the paired PC: places rail on the left, breadcrumb
/// navigation, a sortable file table with drag-and-drop upload, and a transfer bar.
/// Everything shown comes from the agent; unknown values render as "—".
struct MacFilesView: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.macTheme) private var theme

    @State private var selection = Set<MacFileEntry.ID>()
    @State private var dropping = false
    @State private var showsNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: MacFileEntry?
    @State private var renameText = ""
    @State private var moveSelection: MacFilesMoveSelection?
    @State private var pendingRecycle: [MacFileEntry] = []
    @State private var appliedSearch = ""
    @State private var appliedSearchPath: String?

    var body: some View {
        Group {
            if vm.currentPC == nil && !vm.isDemoMode {
                stateCard(tint: theme.accent) { notPairedState }
            } else if vm.isDemoMode {
                stateCard(tint: .orange) { demoState }
            } else if !vm.metrics.isOnline {
                stateCard(tint: .orange) { offlineState }
            } else {
                browser
            }
        }
        .task { await load() }
        .onChange(of: vm.selectedPCID) { _, _ in
            selection = []
            Task { await load() }
        }
        .onChange(of: vm.filesEnabled) { _, enabled in
            if enabled { Task { await load() } }
        }
        .onChange(of: vm.fileEntries) { _, entries in
            let ids = Set(entries.map(\.id))
            selection = selection.intersection(ids)
        }
        .onChange(of: vm.filePath) { _, _ in
            selection = []
            appliedSearch = ""
        }
        .onChange(of: vm.fileSearch) { old, new in handleSearchChange(old: old, new: new) }
        .task(id: vm.filesNotice) { await expireNotice() }
        .alert("New Folder", isPresented: $showsNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("The folder is created inside \(currentFolderName).")
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text(renameTarget.map { "Enter a new name for “\($0.name)”." } ?? "")
        }
        .sheet(item: $moveSelection) { request in
            MacFilesMoveSheet(entries: request.entries).environmentObject(vm)
        }
        .confirmationDialog(recycleTitle, isPresented: recyclePresented, titleVisibility: .visible) {
            Button("Move to Recycle Bin", role: .destructive) {
                let items = pendingRecycle
                pendingRecycle = []
                Task { await vm.recycle(items) }
            }
            Button("Cancel", role: .cancel) { pendingRecycle = [] }
        } message: {
            Text("Items go to the Windows Recycle Bin on \(vm.selectedPCName) and can be restored there.")
        }
    }

    // MARK: - Derived state

    private var canModify: Bool { vm.filesEnabled && vm.filePath != nil && vm.transfer == nil }
    private var selectedEntries: [MacFileEntry] { vm.fileEntries.filter { selection.contains($0.id) } }
    private var hasMore: Bool { vm.fileTruncated || vm.fileEntries.count < vm.fileTotal }
    private var crumbs: [MacFilesCrumb] { vm.filePath.map(MacFilesCrumb.crumbs(for:)) ?? [] }
    private var currentFolderName: String {
        guard let path = vm.filePath else { return "Computer" }
        return crumbs.last?.title ?? path
    }
    private var showsErrorNotice: Bool { vm.filesError != nil && !(vm.filePath == nil && vm.fileRoots == nil) }
    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var recyclePresented: Binding<Bool> {
        Binding(get: { !pendingRecycle.isEmpty }, set: { if !$0 { pendingRecycle = [] } })
    }
    private var recycleTitle: String {
        if pendingRecycle.count == 1 { return "Move “\(pendingRecycle[0].name)” to the Recycle Bin?" }
        return "Move \(pendingRecycle.count) items to the Recycle Bin?"
    }
    private var countLabel: String {
        guard vm.filePath != nil else {
            guard let roots = vm.fileRoots else { return "—" }
            let count = roots.roots.count + roots.shortcuts.count
            return "\(count) location\(count == 1 ? "" : "s")"
        }
        let shown = vm.fileEntries.count
        let total = max(vm.fileTotal, shown)
        var text = shown < total ? "\(shown) of \(total) items" : "\(shown) item\(shown == 1 ? "" : "s")"
        if !selection.isEmpty { text += " · \(selection.count) selected" }
        return text
    }

    // MARK: - Empty / blocked states

    private func stateCard<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        MacPage {
            content()
                .frame(maxWidth: .infinity)
                .macGlass(cornerRadius: 22, tint: tint, elevated: true)
        }
    }

    private var notPairedState: some View {
        MacEmptyState(icon: "desktopcomputer.and.arrow.down", title: "Pair your PC",
                      message: "Browse, download and upload files on your Windows PC once it is paired with Orbit.",
                      tint: theme.accent, actionTitle: "Pair or import a PC") { vm.selectedSection = .pcs }
    }

    private var demoState: some View {
        MacEmptyState(icon: "folder.badge.questionmark", title: "Files need a real PC",
                      message: "Demo mode only simulates telemetry. Pair your Windows PC to browse its drives, download files and upload from this Mac.",
                      tint: .orange, actionTitle: "Pair a PC") {
            vm.setDemoMode(false)
            vm.selectedSection = .pcs
        }
    }

    private var offlineState: some View {
        VStack(spacing: 4) {
            MacEmptyState(icon: "wifi.slash", title: "\(vm.selectedPCName) is offline",
                          message: vm.connectionError ?? "Connect to your PC to browse its files.", tint: .orange)
            HStack(spacing: 10) {
                Button { Task { await vm.wakePC() } } label: { Label(vm.isWaking ? "Waking…" : "Power On", systemImage: "power") }
                    .buttonStyle(MacHoverButtonStyle(tint: .mint, prominent: true))
                    .disabled(vm.isWaking || vm.currentPC?.macAddress.isEmpty == true)
                Button { Task { await vm.refreshMetrics() } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Browser layout

    private var browser: some View {
        HStack(alignment: .top, spacing: 14) {
            rail.frame(width: 200)
            mainArea.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rail: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                placesSection
                favoritesSection
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .macGlass(cornerRadius: 18)
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MacSectionHeader("Places", icon: "desktopcomputer").padding(.bottom, 4)
            MacFilesRailRow(title: "Computer", symbol: "desktopcomputer", tint: theme.accent, isSelected: vm.filePath == nil) {
                vm.openLocation(nil)
            }
            if let roots = vm.fileRoots {
                ForEach(roots.roots) { railRow($0) }
                ForEach(roots.shortcuts) { railRow($0) }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading places…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private func railRow(_ location: MacFileLocation) -> some View {
        let usage = volumeUsage(for: location)
        return MacFilesRailRow(title: location.name, symbol: location.symbol,
                               tint: location.kind == "shortcut" ? theme.secondary : theme.accent,
                               isSelected: vm.filePath == location.path, detail: usage?.label, fraction: usage?.fraction) {
            vm.openLocation(location.path)
        }
        .contextMenu {
            Button("Open") { vm.openLocation(location.path) }
            Button("Copy Path") { copyToPasteboard(location.path) }
            Divider()
            Button(vm.isFavorite(location.path) ? "Remove from Favorites" : "Add to Favorites") { vm.toggleFavorite(location.path) }
        }
        .help(location.path)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MacSectionHeader("Favorites", icon: "star.fill", tint: .yellow).padding(.bottom, 4)
            if vm.fileFavorites.isEmpty {
                Text("Right-click a folder and choose Add to Favorites.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                ForEach(vm.fileFavorites) { favorite in
                    MacFilesRailRow(title: favorite.name, symbol: "folder.fill", tint: .yellow, isSelected: vm.filePath == favorite.path) {
                        vm.openLocation(favorite.path)
                    }
                    .contextMenu {
                        Button("Open") { vm.openLocation(favorite.path) }
                        Button("Copy Path") { copyToPasteboard(favorite.path) }
                        Divider()
                        Button("Remove from Favorites", role: .destructive) { vm.toggleFavorite(favorite.path) }
                    }
                    .help(favorite.path)
                }
            }
        }
    }

    private var mainArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            navigationRow
            actionRow
            notices
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
    }

    // MARK: - Header rows

    private var navigationRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                iconAction("chevron.left", help: "Back (⌘[)") { vm.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!vm.canGoBack)
                iconAction("chevron.right", help: "Forward (⌘])") { vm.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!vm.canGoForward)
                iconAction("arrow.up", help: "Enclosing folder (⌘↑)") { vm.goToParent() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(vm.filePath == nil)
            }
            breadcrumbBar
            if vm.isLoadingFiles { ProgressView().controlSize(.small) }
            iconAction("arrow.clockwise", help: "Refresh (⇧⌘R)") { Task { await vm.refreshFiles() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumbButton(title: "Computer", symbol: "desktopcomputer", isCurrent: vm.filePath == nil) { vm.openLocation(nil) }
                ForEach(crumbs) { crumb in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                    crumbButton(title: crumb.title, symbol: nil, isCurrent: crumb.id == crumbs.count - 1) { vm.openLocation(crumb.path) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .contextMenu {
            if let path = vm.filePath { Button("Copy Path") { copyToPasteboard(path) } }
        }
    }

    private func crumbButton(title: String, symbol: String?, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).lineLimit(1)
            }
            .font(.system(.callout, weight: isCurrent ? .bold : .medium))
            .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.65))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            searchField
            sortPicker
            Spacer(minLength: 0)
            iconAction("folder.badge.plus", help: "New Folder (⇧⌘N)") { newFolderName = ""; showsNewFolder = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canModify)
            iconAction("square.and.arrow.up", help: "Upload files to this folder…") { chooseUploads() }
                .disabled(!canModify)
            iconAction("square.and.arrow.down", help: "Download selection…") { chooseDownloadFolder(for: selectedEntries) }
                .disabled(selectedEntries.isEmpty || vm.transfer != nil)
            iconAction("arrow.up.forward.app", help: "Open (⌘O)") { openEntries(selectedEntries) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(selectedEntries.isEmpty)
            iconAction("trash", help: "Move to Recycle Bin (⌫)") { pendingRecycle = selectedEntries }
                .disabled(selectedEntries.isEmpty || !canModify)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search this folder", text: $vm.fileSearch)
                .textFieldStyle(.plain)
                .onSubmit { submitSearch() }
            if !vm.fileSearch.isEmpty {
                Button { vm.fileSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .frame(minWidth: 150, maxWidth: 280)
        .disabled(vm.filePath == nil)
    }

    private var sortPicker: some View {
        Picker("Sort", selection: Binding(get: { vm.fileSort }, set: { newValue in
            guard newValue != vm.fileSort else { return }
            vm.fileSort = newValue
            Task { await vm.refreshFiles() }
        })) {
            ForEach(MacFileSort.allCases) { sort in Text(sort.title).tag(sort) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 140)
        .help("Sort order")
        .accessibilityLabel("Sort order")
        .disabled(vm.filePath == nil)
    }

    private func iconAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(MacIconButtonStyle(size: 28))
            .help(help)
            .accessibilityLabel(help)
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let notice = vm.filesNotice {
            MacNotice(title: "Files", message: notice, icon: "checkmark.circle.fill", tint: .mint)
                .onTapGesture { vm.filesNotice = nil }
        }
        if let error = vm.filesError, showsErrorNotice {
            ZStack(alignment: .topTrailing) {
                MacNotice(title: "Something went wrong", message: error, icon: "exclamationmark.triangle.fill", tint: .orange)
                Button { vm.filesError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(MacIconButtonStyle(size: 22))
                    .padding(8)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.filePath == nil {
            locationsOverview
        } else {
            fileTable
        }
    }

    private var tileColumns: [GridItem] { [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 10)] }

    @ViewBuilder
    private var locationsOverview: some View {
        if let roots = vm.fileRoots {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    locationsHero(roots)
                    if !roots.roots.isEmpty {
                        MacSectionHeader("Drives", icon: "internaldrive.fill")
                        LazyVGrid(columns: tileColumns, spacing: 10) {
                            ForEach(roots.roots) { location in
                                MacFilesLocationTile(location: location, usage: volumeUsage(for: location), tint: theme.accent) { vm.openLocation(location.path) }
                            }
                        }
                    }
                    if !roots.shortcuts.isEmpty {
                        MacSectionHeader("Folders", icon: "folder.fill")
                        LazyVGrid(columns: tileColumns, spacing: 10) {
                            ForEach(roots.shortcuts) { location in
                                MacFilesLocationTile(location: location, usage: nil, tint: theme.secondary) { vm.openLocation(location.path) }
                            }
                        }
                    }
                    if roots.roots.isEmpty && roots.shortcuts.isEmpty {
                        MacEmptyState(icon: "externaldrive.badge.questionmark", title: "No locations",
                                      message: "The PC didn't report any drives or folders.", tint: theme.accent)
                    }
                }
                .padding(16)
            }
            .macGlass(cornerRadius: 18)
        } else if let error = vm.filesError {
            MacEmptyState(icon: "folder.badge.gearshape", title: "File access unavailable",
                          message: "\(error) If this keeps happening, turn on file access in Orbit Companion on the PC.",
                          tint: .orange, actionTitle: "Try Again") { Task { await vm.refreshFiles() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .macGlass(cornerRadius: 18, tint: .orange)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading locations on \(vm.selectedPCName)…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .macGlass(cornerRadius: 18)
        }
    }

    private func locationsHero(_ roots: MacFileRoots) -> some View {
        HStack(spacing: 14) {
            MacIconBadge(systemName: "folder.fill", tint: theme.accent, size: 44, filled: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Files on \(vm.selectedPCName)")
                    .font(.system(.title3, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    MacStatChip(label: "Drives", value: "\(roots.roots.count)", icon: "internaldrive.fill")
                    MacStatChip(label: "Folders", value: "\(roots.shortcuts.count)", icon: "folder.fill")
                    MacStatChip(label: "Favorites", value: "\(vm.fileFavorites.count)", icon: "star.fill", tint: .yellow)
                    if vm.currentPC?.isSecure == true {
                        MacStatusPill(text: "Encrypted", tint: .mint, icon: "lock.fill")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .macGlass(cornerRadius: 16, tint: theme.accent, elevated: true)
    }

    private var fileTable: some View {
        ZStack {
            Table(vm.fileEntries, selection: $selection) {
                TableColumn("Name") { entry in nameCell(entry) }
                    .width(min: 180, ideal: 320)
                TableColumn("Date Modified") { entry in
                    Text(Self.modifiedLabel(entry)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 130, ideal: 150)
                TableColumn("Size") { entry in
                    Text(entry.sizeLabel).foregroundStyle(.secondary).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Kind") { entry in
                    Text(MacFilesKind.label(for: entry)).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 130)
            }
            .tableStyle(.inset)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: MacFileEntry.ID.self) { ids in
                contextMenuItems(for: ids)
            } primaryAction: { ids in
                openEntries(entries(for: ids))
            }
            .onDeleteCommand {
                if !selectedEntries.isEmpty, canModify { pendingRecycle = selectedEntries }
            }
            tableOverlay
            if dropping { dropOverlay }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .macGlass(cornerRadius: 18)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in handleDrop(providers) }
    }

    private func nameCell(_ entry: MacFileEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(entry.tint)
                .frame(width: 18)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            if entry.isDirectory && vm.isFavorite(entry.path) {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
            }
        }
        .help(entry.path)
    }

    @ViewBuilder
    private var tableOverlay: some View {
        if vm.isLoadingFiles && vm.fileEntries.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading \(currentFolderName)…").font(.caption).foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        } else if vm.fileEntries.isEmpty {
            if appliedSearch.isEmpty {
                MacEmptyState(icon: "folder", title: "Empty folder",
                              message: "Drop files here or use Upload to copy files from this Mac to \(currentFolderName).",
                              tint: theme.accent, actionTitle: canModify ? "Upload files…" : nil) { chooseUploads() }
            } else {
                MacEmptyState(icon: "magnifyingglass", title: "No matches",
                              message: "Nothing in \(currentFolderName) matches “\(appliedSearch)”.", tint: theme.accent)
            }
        }
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(canModify ? "Drop to upload to \(currentFolderName)" : "Open a folder first")
                    .font(.headline.weight(.semibold))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let transfer = vm.transfer { transferBar(transfer) }
            HStack(spacing: 10) {
                Text(countLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if vm.isLoadingFiles && !vm.fileEntries.isEmpty { ProgressView().controlSize(.mini) }
                Spacer()
                if vm.filePath != nil, hasMore {
                    Button { Task { await vm.loadMoreFiles() } } label: { Label("Show more", systemImage: "chevron.down") }
                        .buttonStyle(MacHoverButtonStyle(tint: theme.accent))
                        .disabled(vm.isLoadingFiles)
                }
            }
        }
    }

    private func transferBar(_ transfer: MacTransferState) -> some View {
        HStack(spacing: 12) {
            MacIconBadge(systemName: "arrow.up.arrow.down.circle.fill", tint: theme.accent, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(transfer.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(Self.transferDetail(transfer)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if transfer.indeterminate {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                } else {
                    ProgressView(value: transfer.progress).controlSize(.small).tint(theme.accent)
                }
                Text(transfer.phase).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { vm.cancelTransfer() } label: { Image(systemName: "xmark") }
                .buttonStyle(MacIconButtonStyle(size: 26))
                .help("Cancel transfer")
                .accessibilityLabel("Cancel transfer")
        }
        .padding(12)
        .macGlass(cornerRadius: 14, tint: theme.accent)
    }

    private static func transferDetail(_ transfer: MacTransferState) -> String {
        guard !transfer.indeterminate else { return "" }
        var text = "\(Int((min(1, max(0, transfer.progress)) * 100).rounded()))%"
        if transfer.bytesPerSecond > 0 { text += " · \(MacFormat.transferRate(transfer.bytesPerSecond / 1_000_000))" }
        return text
    }

    private static func modifiedLabel(_ entry: MacFileEntry) -> String {
        entry.modifiedDate.map { $0.formatted(.dateTime.day().month().year().hour().minute()) } ?? "—"
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenuItems(for ids: Set<MacFileEntry.ID>) -> some View {
        let items = entries(for: ids)
        if items.isEmpty {
            Button("New Folder…") { newFolderName = ""; showsNewFolder = true }.disabled(!canModify)
            Button("Upload Files…") { chooseUploads() }.disabled(!canModify)
            Button("Refresh") { Task { await vm.refreshFiles() } }
        } else {
            Button(items.count == 1 && items[0].isDirectory ? "Open" : "Open with Default App") { openEntries(items) }
            Button("Download…") { chooseDownloadFolder(for: items) }.disabled(vm.transfer != nil)
            Divider()
            if items.count == 1 {
                Button("Rename…") { renameText = items[0].name; renameTarget = items[0] }.disabled(!canModify)
            }
            Button("Move to…") { moveSelection = MacFilesMoveSelection(entries: items) }.disabled(!canModify)
            Button("Copy Path") { copyToPasteboard(items.map(\.path).joined(separator: "\n")) }
            let folders = items.filter(\.isDirectory)
            if folders.count == 1 {
                Button(vm.isFavorite(folders[0].path) ? "Remove from Favorites" : "Add to Favorites") { vm.toggleFavorite(folders[0].path) }
            }
            Divider()
            Button("Move to Recycle Bin", role: .destructive) { pendingRecycle = items }.disabled(!canModify)
        }
    }

    // MARK: - Actions

    private func load() async {
        vm.loadFavorites()
        guard vm.filesEnabled else { return }
        await vm.refreshFiles()
    }

    private func entries(for ids: Set<MacFileEntry.ID>) -> [MacFileEntry] {
        vm.fileEntries.filter { ids.contains($0.id) }
    }

    private func openEntries(_ items: [MacFileEntry]) {
        guard let first = items.first else { return }
        if first.isDirectory {
            vm.openLocation(first.path)
        } else {
            Task { await vm.openWithDefaultApp(first) }
        }
    }

    private func submitSearch() {
        appliedSearch = vm.fileSearch
        appliedSearchPath = vm.filePath
        Task { await vm.refreshFiles() }
    }

    /// Re-runs the listing when the user clears a submitted search. Navigation also
    /// clears `fileSearch`, but it already reloads, so that case is skipped.
    private func handleSearchChange(old: String, new: String) {
        guard new.isEmpty, !old.isEmpty else { return }
        guard !appliedSearch.isEmpty, appliedSearchPath == vm.filePath else { appliedSearch = ""; return }
        appliedSearch = ""
        Task { await vm.refreshFiles() }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty, canModify else { return }
        Task { await vm.createFolder(named: name) }
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renameTarget else { return }
        renameTarget = nil
        guard !name.isEmpty, name != target.name, canModify else { return }
        Task { await vm.rename(target, to: name) }
    }

    private func chooseUploads() {
        guard canModify else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files to upload to \(currentFolderName) on \(vm.selectedPCName)."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        Task { await vm.upload(urls) }
    }

    private func chooseDownloadFolder(for items: [MacFileEntry]) {
        guard !items.isEmpty, vm.transfer == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where to save \(items.count) item\(items.count == 1 ? "" : "s"). Folders are downloaded as ZIP archives."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await vm.download(items, to: url, revealInFinder: true) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canModify else { return false }
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty else { return false }
        Task { @MainActor in
            let urls = await MacFilesDropLoader.urls(from: candidates)
            guard !urls.isEmpty else { return }
            await vm.upload(urls)
        }
        return true
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        vm.filesNotice = "Copied to the Mac clipboard."
    }

    private func expireNotice() async {
        guard let notice = vm.filesNotice else { return }
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled, vm.filesNotice == notice else { return }
        vm.filesNotice = nil
    }

    /// Matches a drive root against the volumes reported by `/api/specs`; nil when unknown.
    private func volumeUsage(for location: MacFileLocation) -> MacFilesVolumeUsage? {
        guard location.kind != "shortcut", let volumes = vm.specs?.volumes else { return nil }
        let target = Self.normalizedDrive(location.path)
        guard !target.isEmpty,
              let volume = volumes.first(where: { Self.normalizedDrive($0.mountpoint ?? "") == target }),
              let total = volume.totalGB, let used = volume.usedGB, total > 0 else { return nil }
        let free = max(0, total - used)
        return MacFilesVolumeUsage(fraction: min(1, max(0, used / total)), label: "\(MacFormat.decimal(free, digits: 0)) GB free of \(MacFormat.decimal(total, digits: 0)) GB")
    }

    private static func normalizedDrive(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        while value.hasSuffix("\\") || value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

// MARK: - Helper types

private struct MacFilesCrumb: Identifiable, Hashable {
    let id: Int
    let title: String
    let path: String

    /// Splits a Windows path into clickable prefixes ("C:\", "C:\Users", …).
    static func crumbs(for path: String) -> [MacFilesCrumb] {
        let isUNC = path.hasPrefix("\\\\")
        let parts = path.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        var result: [MacFilesCrumb] = []
        for index in parts.indices {
            var partial = parts[0...index].joined(separator: "\\")
            if isUNC { partial = "\\\\" + partial }
            if index == 0 && !isUNC && partial.hasSuffix(":") { partial += "\\" }
            result.append(MacFilesCrumb(id: index, title: parts[index], path: partial))
        }
        return result
    }
}

private struct MacFilesVolumeUsage {
    let fraction: Double
    let label: String
}

private struct MacFilesMoveSelection: Identifiable {
    let id = UUID()
    let entries: [MacFileEntry]
}

private struct MacFilesQuickPick: Identifiable, Hashable {
    let name: String
    let path: String
    let symbol: String
    var id: String { path }
}

private enum MacFilesKind {
    static func label(for entry: MacFileEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = entry.fileExtension
        switch ext {
        case "": return "Document"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff": return "\(ext.uppercased()) image"
        case "mp4", "mov", "mkv", "avi", "webm": return "\(ext.uppercased()) video"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg": return "\(ext.uppercased()) audio"
        case "pdf": return "PDF document"
        case "zip", "7z", "rar", "tar", "gz": return "\(ext.uppercased()) archive"
        case "exe": return "Application"
        case "msi": return "Installer package"
        case "bat", "cmd", "ps1": return "Script"
        case "lnk": return "Shortcut"
        case "txt", "md", "log": return "Text document"
        case "json", "xml", "csv", "ini", "yaml", "yml": return "\(ext.uppercased()) data"
        case "py", "swift", "js", "ts", "cs", "cpp", "c", "h", "java", "rs", "go": return "Source code"
        default: return "\(ext.uppercased()) file"
        }
    }
}

/// Resolves dropped `public.file-url` items to local URLs off the main thread.
private enum MacFilesDropLoader {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider) { urls.append(url) }
        }
        return urls
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolved: URL?
                if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolved = url
                } else if let text = item as? String {
                    resolved = URL(string: text)
                } else {
                    resolved = nil
                }
                continuation.resume(returning: resolved)
            }
        }
    }
}

// MARK: - Rail row

private struct MacFilesRailRow: View {
    var title: String
    var symbol: String
    var tint: Color
    var isSelected: Bool
    var detail: String? = nil
    var fraction: Double? = nil
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(.callout, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                if let fraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.08))
                            Capsule().fill(tint.opacity(0.8))
                                .frame(width: max(2, geometry.size.width * CGFloat(min(1, max(0, fraction)))))
                        }
                    }
                    .frame(height: 3)
                    .padding(.leading, 26)
                }
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 26)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.18) : Color.white.opacity(hovered ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

// MARK: - Location tile

private struct MacFilesLocationTile: View {
    let location: MacFileLocation
    let usage: MacFilesVolumeUsage?
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MacIconBadge(systemName: location.symbol, tint: tint, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(location.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                if let usage {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.07))
                            Capsule().fill(tint)
                                .frame(width: max(4, geometry.size.width * CGFloat(usage.fraction)))
                        }
                    }
                    .frame(height: 4)
                    Text(usage.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .macGlass(cornerRadius: 14, tint: tint, hovered: hovered)
        .onHover { hovered = $0 }
        .macHoverLift()
        .help(location.path)
        .accessibilityLabel(location.name)
    }
}

// MARK: - Move sheet

private struct MacFilesMoveSheet: View {
    @EnvironmentObject var vm: OrbitMacViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macTheme) private var theme
    let entries: [MacFileEntry]
    @State private var destination = ""

    private var trimmed: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canMove: Bool { !trimmed.isEmpty && trimmed != (vm.filePath ?? "") }

    private var quickPicks: [MacFilesQuickPick] {
        var seen = Set<String>()
        var picks: [MacFilesQuickPick] = []
        func add(_ name: String, _ path: String, _ symbol: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            picks.append(MacFilesQuickPick(name: name, path: path, symbol: symbol))
        }
        let moving = Set(entries.map(\.path))
        if let parent = vm.fileParentPath { add("Enclosing folder", parent, "arrow.turn.left.up") }
        for folder in vm.fileEntries where folder.isDirectory && !moving.contains(folder.path) { add(folder.name, folder.path, "folder.fill") }
        for favorite in vm.fileFavorites { add(favorite.name, favorite.path, "star.fill") }
        if let roots = vm.fileRoots {
            for shortcut in roots.shortcuts { add(shortcut.name, shortcut.path, shortcut.symbol) }
            for root in roots.roots { add(root.name, root.path, root.symbol) }
        }
        return picks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(entries.count) item\(entries.count == 1 ? "" : "s")").font(.title3.weight(.bold))
            Text("Destination folder on \(vm.selectedPCName). Items are moved on the PC; nothing is copied to this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("C:\\Users\\…", text: $destination)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            MacSectionHeader("Quick Picks", icon: "bolt.fill")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(quickPicks) { pick in
                        MacFilesRailRow(title: pick.name, symbol: pick.symbol, tint: theme.accent, isSelected: pick.path == trimmed, detail: pick.path) {
                            destination = pick.path
                        }
                    }
                    if quickPicks.isEmpty {
                        Text("Type a folder path above.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MacHoverButtonStyle())
                Button("Move") {
                    let target = trimmed
                    dismiss()
                    Task { await vm.move(entries, toDirectory: target) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(MacHoverButtonStyle(tint: theme.accent, prominent: true))
                .disabled(!canMove)
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
        .background(MacAmbientBackground())
        .onAppear { destination = vm.filePath ?? "" }
    }
}
