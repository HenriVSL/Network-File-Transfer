//
//  DirectoryView.swift
//  Network File Transfer
//

import SwiftUI
import UniformTypeIdentifiers

struct DirectoryView: View {
    let path: String
    let title: String

    @Environment(BrowserSession.self) private var session
    @Environment(TransferManager.self) private var transfers
    @Environment(DownloadLocation.self) private var downloadLocation
    @Environment(Server.self) private var server
    @Environment(NavigationRouter.self) private var router

    @AppStorage("showHiddenFiles") private var showHidden = false
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .name

    @State private var files: [RemoteFile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selection = Set<RemoteFile.ID>()
    @State private var editMode: EditMode = .inactive

    @State private var importer: Importer?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteFile] = []
    @State private var toast: String?

    /// One file importer serves both uploads and picking a "Download To…" folder.
    enum Importer {
        case upload
        case downloadTo([RemoteFile])
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, date, size
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .date: "Date Modified"
            case .size: "Size"
            }
        }
    }

    private var visibleFiles: [RemoteFile] {
        files
            .filter { showHidden || !$0.isHidden }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                switch sortOrder {
                case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                case .date: return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
                case .size: return (a.size ?? 0) > (b.size ?? 0)
                }
            }
    }

    private var selectedFiles: [RemoteFile] {
        files.filter { selection.contains($0.id) }
    }

    var body: some View {
        List(selection: $selection) {
            if path != "/" && editMode == .inactive && searchText.isEmpty {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .listRowBackground(Color.clear)
            }
            ForEach(visibleFiles) { file in
                row(for: file)
            }
        }
        .listStyle(.plain)
        .overlay { overlayContent }
        .overlay(alignment: .bottom) { toastView }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter")
        .refreshable { await load() }
        .environment(\.editMode, $editMode)
        .toolbar { toolbarContent }
        .task { await load() }
        .onChange(of: session.changeCounter) {
            if session.lastChangedDirectory == path { Task { await load() } }
        }
        .onChange(of: transfers.lastUpload) { _, event in
            if let event, event.serverID == session.info.serverID, event.directory == path {
                Task { await load() }
            }
        }
        .fileImporter(
            isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
            allowedContentTypes: importerIsUpload ? [.item] : [.folder],
            allowsMultipleSelection: importerIsUpload
        ) { result in
            switch importer {
            case .upload: upload(result)
            case .downloadTo(let files): download(files, toPickedFolder: result)
            case nil: break
            }
            importer = nil
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
        }
        .confirmationDialog(
            deleteTargets.count == 1 ? "Delete \"\(deleteTargets[0].name)\"?" : "Delete \(deleteTargets.count) items?",
            isPresented: Binding(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete(deleteTargets) }
        } message: {
            Text(deleteTargets.contains(where: \.isDirectory) ? "Folders are deleted with all of their contents. This can't be undone." : "This can't be undone.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for file: RemoteFile) -> some View {
        Group {
            if file.isDirectory || file.kind == .symlink {
                NavigationLink(value: DirectoryRoute(path: file.path, name: file.name)) {
                    FileRow(file: file)
                }
            } else {
                Button {
                    download([file])
                } label: {
                    FileRow(file: file)
                }
                .tint(.primary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTargets = [file] }
            Button("Rename", systemImage: "pencil") { startRename(file) }
                .tint(.gray)
        }
        .swipeActions(edge: .leading) {
            if !file.isDirectory {
                Button("Download", systemImage: "arrow.down.circle") { download([file]) }
                    .tint(.accentColor)
                Button("Download To…", systemImage: "folder") { importer = .downloadTo([file]) }
                    .tint(.indigo)
            }
        }
        .contextMenu {
            if !file.isDirectory {
                Button("Download", systemImage: "arrow.down.circle") { download([file]) }
                Button("Download To…", systemImage: "folder") { importer = .downloadTo([file]) }
            }
            if file.isDirectory {
                Button(
                    server.isBookmarked(file.path) ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: server.isBookmarked(file.path) ? "bookmark.slash" : "bookmark"
                ) {
                    toggleBookmark(file.path)
                }
            }
            Button("Rename", systemImage: "pencil") { startRename(file) }
            Button("Copy Path", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = file.path
                showToast("Path copied")
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTargets = [file] }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if isLoading && files.isEmpty {
            ProgressView()
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { Task { await load() } }
            }
        } else if visibleFiles.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                } actions: {
                    Button("Upload Files") { importer = .upload }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: .capsule)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    editMode = .inactive
                    selection.removeAll()
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Download", systemImage: "arrow.down.circle") {
                    download(selectedFiles.filter { !$0.isDirectory })
                    editMode = .inactive
                    selection.removeAll()
                }
                .disabled(selectedFiles.allSatisfy(\.isDirectory))
                Button("Download To…", systemImage: "folder") {
                    importer = .downloadTo(selectedFiles.filter { !$0.isDirectory })
                    editMode = .inactive
                    selection.removeAll()
                }
                .disabled(selectedFiles.allSatisfy(\.isDirectory))
                Spacer()
                Text(selection.isEmpty ? "Select Items" : "\(selection.count) Selected")
                    .font(.subheadline)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    deleteTargets = selectedFiles
                }
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Upload Files", systemImage: "square.and.arrow.up") { importer = .upload }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showNewFolder = true
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                bookmarksMenu
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu("View", systemImage: "ellipsis") {
                    Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Show Hidden Files", systemImage: "eye", isOn: $showHidden)
                }
            }
        }
    }

    private var bookmarksMenu: some View {
        Menu("Bookmarks", systemImage: server.isBookmarked(path) ? "bookmark.fill" : "bookmark") {
            Button(
                server.isBookmarked(path) ? "Remove Bookmark" : "Bookmark This Folder",
                systemImage: server.isBookmarked(path) ? "bookmark.slash" : "bookmark"
            ) {
                toggleBookmark(path)
            }
            if !server.bookmarks.isEmpty {
                Section("Go To") {
                    ForEach(server.bookmarks.filter { $0 != path }, id: \.self) { bookmark in
                        Button {
                            router.open(folder: bookmark)
                        } label: {
                            Label(DirectoryRoute.displayName(for: bookmark), systemImage: "folder")
                            Text(bookmark)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleBookmark(_ folder: String) {
        server.toggleBookmark(folder)
        let name = DirectoryRoute.displayName(for: folder)
        showToast(server.isBookmarked(folder) ? "Bookmarked \(name)" : "Removed bookmark for \(name)")
    }

    private func load() async {
        isLoading = true
        do {
            files = try await session.list(path)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var importerIsUpload: Bool {
        if case .upload = importer { return true }
        return false
    }

    /// Downloads to the default location chosen in the Downloads tab.
    private func download(_ selected: [RemoteFile]) {
        download(selected, to: downloadLocation.customFolder, folderName: downloadLocation.displayName)
    }

    private func download(_ selected: [RemoteFile], toPickedFolder result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let folder = urls.first else { return }
        download(selected, to: folder, folderName: folder.lastPathComponent)
    }

    private func download(_ selected: [RemoteFile], to folder: URL?, folderName: String) {
        guard !selected.isEmpty else { return }
        for file in selected {
            transfers.download(file, from: session.info, to: folder)
        }
        let what = selected.count == 1 ? selected[0].name : "\(selected.count) files"
        showToast("Downloading \(what) to \(folderName)")
    }

    private func upload(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        var queued = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Copy into tmp so the transfer can outlive the security-scoped access.
            let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let copy = folder.appending(path: url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
                transfers.upload(copy, to: path, info: session.info)
                queued += 1
            } catch {
                showToast("Couldn't read \(url.lastPathComponent)")
            }
        }
        if queued > 0 { showToast(queued == 1 ? "Uploading \(urls[0].lastPathComponent)" : "Uploading \(queued) files") }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await session.createDirectory(named: name, in: path)
            } catch {
                errorAlert(error)
            }
        }
    }

    private func startRename(_ file: RemoteFile) {
        renameText = file.name
        renameTarget = file
    }

    private func rename() {
        guard let file = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != file.name else { return }
        Task {
            do {
                try await session.rename(file, to: name)
            } catch {
                errorAlert(error)
            }
        }
    }

    private func delete(_ targets: [RemoteFile]) {
        editMode = .inactive
        selection.removeAll()
        Task {
            for file in targets {
                do {
                    try await session.delete(file)
                } catch {
                    errorAlert(error)
                    break
                }
            }
        }
    }

    private func errorAlert(_ error: Error) {
        showToast(error.localizedDescription)
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { withAnimation { toast = nil } }
        }
    }
}

struct FileRow: View {
    let file: RemoteFile

    var body: some View {
        let icon = Formatting.icon(for: file)
        HStack(spacing: 12) {
            Image(systemName: icon.name)
                .font(.title3)
                .foregroundStyle(icon.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(file.isHidden ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let modified = file.modified {
                        Text(modified, format: .dateTime.year().month().day().hour().minute())
                    }
                    if !file.isDirectory, let size = file.size {
                        Text(Formatting.bytes(size))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
