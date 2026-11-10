//
//  TransfersView.swift
//  Network File Transfer
//

import QuickLook
import SwiftData
import SwiftUI

struct TransfersView: View {
    @Environment(TransferManager.self) private var transfers
    @Query private var servers: [Server]
    @State private var previewURL: URL?
    /// Folder from Files whose security-scoped access is held while its file is previewed.
    @State private var accessedFolder: URL?

    var body: some View {
        NavigationStack {
            Group {
                if transfers.items.isEmpty {
                    ContentUnavailableView(
                        "No Transfers",
                        systemImage: "arrow.up.arrow.down",
                        description: Text("Uploads and downloads you start will show up here.")
                    )
                } else {
                    List(transfers.items) { item in
                        TransferRow(item: item)
                            .contentShape(.rect)
                            .onTapGesture {
                                if item.direction == .download, item.state == .completed {
                                    if let folder = item.destinationFolder, folder.startAccessingSecurityScopedResource() {
                                        accessedFolder = folder
                                    }
                                    previewURL = item.localURL
                                }
                            }
                            .swipeActions {
                                if item.isActive {
                                    Button("Cancel", systemImage: "xmark", role: .destructive) {
                                        transfers.cancel(item)
                                    }
                                } else if item.state != .completed, let info = connectionInfo(for: item) {
                                    Button("Retry", systemImage: "arrow.clockwise") {
                                        transfers.retry(item, info: info)
                                    }
                                    .tint(.accentColor)
                                }
                            }
                    }
                }
            }
            .navigationTitle("Transfers")
            .toolbar {
                if transfers.items.contains(where: { !$0.isActive }) {
                    Button("Clear Finished") { transfers.clearFinished() }
                }
            }
            .quickLookPreview($previewURL)
            .onChange(of: previewURL) { _, url in
                if url == nil, let folder = accessedFolder {
                    folder.stopAccessingSecurityScopedResource()
                    accessedFolder = nil
                }
            }
        }
    }

    private func connectionInfo(for item: TransferItem) -> ConnectionInfo? {
        // Uploads delete their temp copy on success only, so a failed upload can be retried.
        if item.direction == .upload, !FileManager.default.fileExists(atPath: item.localURL.path) { return nil }
        return servers.first { $0.id == item.serverID }?.connectionInfo()
    }
}

struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.state == .running {
                    if let fraction = item.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView(value: 0).opacity(0.3)
                    }
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(item.state.isFailure ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch item.state {
        case .completed: .green
        case .failed: .red
        case .cancelled: .gray
        default: .accentColor
        }
    }

    private var statusText: String {
        switch item.state {
        case .queued:
            return "Waiting · \(item.serverName)"
        case .running:
            let done = Formatting.bytes(item.completedBytes)
            if let total = item.totalBytes {
                return "\(done) of \(Formatting.bytes(total)) · \(item.serverName)"
            }
            return "\(done) · \(item.serverName)"
        case .completed:
            let size = Formatting.bytes(item.totalBytes ?? item.completedBytes)
            return item.direction == .download
                ? "Saved \(size) to \(item.destinationFolder?.lastPathComponent ?? "On My iPhone") · Tap to open" : "Uploaded \(size) to \(item.serverName)"
        case .cancelled:
            return "Cancelled"
        case .failed(let message):
            return message
        }
    }
}

extension TransferItem.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
