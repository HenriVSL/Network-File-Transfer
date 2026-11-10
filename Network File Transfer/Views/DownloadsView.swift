//
//  DownloadsView.swift
//  Network File Transfer
//

import QuickLook
import SwiftUI

/// Browses downloaded files on the device. These also appear in the Files app
/// under "On My iPhone › Network File Transfer".
struct DownloadsView: View {
    @Environment(DownloadLocation.self) private var downloadLocation
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            LocalFolderView(url: TransferManager.downloadsDirectory, title: "Downloads")
                .safeAreaInset(edge: .top) {
                    if downloadLocation.customFolder != nil {
                        Label("New downloads are saved to \"\(downloadLocation.displayName)\" in Files.", systemImage: "folder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.bar)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Save Location", systemImage: "folder.badge.gearshape") {
                            Section("Save Downloads To") {
                                Button {
                                    downloadLocation.useAppFolder()
                                } label: {
                                    Label("On My iPhone (App Folder)", systemImage: downloadLocation.customFolder == nil ? "checkmark" : "iphone")
                                }
                                if let folder = downloadLocation.customFolder {
                                    Button {} label: {
                                        Label(folder.lastPathComponent, systemImage: "checkmark")
                                    }
                                }
                                Button("Choose Folder in Files…", systemImage: "folder") {
                                    showFolderPicker = true
                                }
                            }
                        }
                    }
                }
                .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        downloadLocation.setCustomFolder(url)
                    }
                }
        }
    }
}

struct LocalFolderView: View {
    let url: URL
    let title: String

    @Environment(TransferManager.self) private var transfers
    @State private var items: [URL] = []
    @State private var previewURL: URL?
    @State private var deleteTarget: URL?

    var body: some View {
        List {
            ForEach(items, id: \.self) { item in
                let isDirectory = Self.isDirectory(item)
                Group {
                    if isDirectory {
                        NavigationLink {
                            LocalFolderView(url: item, title: item.lastPathComponent)
                        } label: {
                            LocalFileRow(url: item, isDirectory: true)
                        }
                    } else {
                        Button {
                            previewURL = item
                        } label: {
                            LocalFileRow(url: item, isDirectory: false)
                        }
                        .tint(.primary)
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = item }
                }
                .contextMenu {
                    ShareLink(item: item)
                    Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = item }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloads saved on this iPhone appear here and in the Files app under On My iPhone › Network File Transfer.")
                )
            }
        }
        .navigationTitle(title)
        .quickLookPreview($previewURL, in: items.filter { !Self.isDirectory($0) })
        .refreshable { reload() }
        .onAppear { reload() }
        .onChange(of: transfers.items.filter { $0.state == .completed }.count) { reload() }
        .confirmationDialog(
            "Delete \"\(deleteTarget?.lastPathComponent ?? "")\"?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    try? FileManager.default.removeItem(at: target)
                    reload()
                }
            }
        }
    }

    private func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        items = contents.sorted { a, b in
            let aDir = Self.isDirectory(a), bDir = Self.isDirectory(b)
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

struct LocalFileRow: View {
    let url: URL
    let isDirectory: Bool

    var body: some View {
        let icon = isDirectory ? ("folder.fill", Color.accentColor) : Formatting.icon(forExtension: url.pathExtension.lowercased())
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        HStack(spacing: 12) {
            Image(systemName: icon.0)
                .font(.title3)
                .foregroundStyle(icon.1)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let date = values?.contentModificationDate {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                    if !isDirectory, let size = values?.fileSize {
                        Text(Formatting.bytes(Int64(size)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}
