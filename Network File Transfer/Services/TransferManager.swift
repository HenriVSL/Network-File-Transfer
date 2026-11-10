//
//  TransferManager.swift
//  Network File Transfer
//

import Foundation
import Observation
import UIKit

@Observable
final class TransferItem: Identifiable {
    enum Direction { case upload, download }

    enum State: Equatable {
        case queued, running, completed, cancelled
        case failed(String)
    }

    let id = UUID()
    let fileName: String
    let serverID: UUID
    let serverName: String
    let direction: Direction
    /// For downloads: the temporary file while running, then the saved file once completed.
    var localURL: URL
    let remotePath: String
    /// Folder picked in the Files app to save a download into; nil means the app's own folder.
    let destinationFolder: URL?
    let startedAt = Date()

    var state: State = .queued
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
    fileprivate var task: Task<Void, Never>?

    init(fileName: String, serverID: UUID, serverName: String, direction: Direction, localURL: URL, remotePath: String, destinationFolder: URL? = nil) {
        self.fileName = fileName
        self.serverID = serverID
        self.serverName = serverName
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.destinationFolder = destinationFolder
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    var isActive: Bool { state == .queued || state == .running }
}

/// Runs uploads and downloads. Each transfer uses its own connection so browsing stays responsive.
@Observable
final class TransferManager {
    private(set) var items: [TransferItem] = []

    struct UploadEvent: Equatable {
        let id = UUID()
        let serverID: UUID
        let directory: String
    }

    /// Set after each finished upload so open directory listings can refresh.
    private(set) var lastUpload: UploadEvent?

    var activeCount: Int { items.filter(\.isActive).count }

    private let background = BackgroundTransferCoordinator()

    init() {
        background.onExpiration = { [weak self] in
            self?.items.filter(\.isActive).forEach { $0.task?.cancel() }
        }
    }

    static var downloadsDirectory: URL {
        let url = URL.documentsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Downloads a file into `folder` (a security-scoped folder picked in Files), or the app's
    /// own Downloads folder when nil. Data goes to a temp file first and is moved in when complete.
    func download(_ file: RemoteFile, from info: ConnectionInfo, to folder: URL? = nil) {
        let item = TransferItem(
            fileName: file.name, serverID: info.serverID, serverName: info.name, direction: .download,
            localURL: Self.temporaryDownloadURL(), remotePath: file.path, destinationFolder: folder
        )
        item.totalBytes = file.size
        start(item, info: info)
    }

    /// Uploads a local file. `localURL` should be a copy the app owns (e.g. in tmp), and is removed afterwards.
    func upload(_ localURL: URL, to directory: String, info: ConnectionInfo) {
        let remotePath = RemotePath.join(directory, localURL.lastPathComponent)
        let item = TransferItem(fileName: localURL.lastPathComponent, serverID: info.serverID, serverName: info.name, direction: .upload, localURL: localURL, remotePath: remotePath)
        start(item, info: info)
    }

    func cancel(_ item: TransferItem) {
        item.task?.cancel()
    }

    func retry(_ item: TransferItem, info: ConnectionInfo) {
        items.removeAll { $0.id == item.id }
        let copy = TransferItem(
            fileName: item.fileName, serverID: item.serverID, serverName: item.serverName, direction: item.direction,
            localURL: item.direction == .download ? Self.temporaryDownloadURL() : item.localURL,
            remotePath: item.remotePath, destinationFolder: item.destinationFolder
        )
        copy.totalBytes = item.totalBytes
        start(copy, info: info)
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    private func start(_ item: TransferItem, info: ConnectionInfo) {
        items.insert(item, at: 0)
        background.transferStarted(item)
        item.task = Task {
            defer { background.update() }
            let background = UIApplication.shared.beginBackgroundTask(withName: "Transfer \(item.fileName)")
            defer { UIApplication.shared.endBackgroundTask(background) }

            let client = ClientFactory.make(info)
            let progress: ProgressHandler = { completed, total in
                Task { @MainActor in
                    item.completedBytes = completed
                    if let total { item.totalBytes = total }
                    self.background.update()
                }
            }
            do {
                item.state = .running
                try await client.connect()
                switch item.direction {
                case .download:
                    try await client.download(item.remotePath, to: item.localURL, progress: progress)
                case .upload:
                    try await client.upload(item.localURL, to: item.remotePath, progress: progress)
                }
                await client.disconnect()
                try Task.checkCancellation()
                if item.direction == .download {
                    item.localURL = try saveDownload(item)
                }
                item.state = .completed
                if let total = item.totalBytes { item.completedBytes = total }
                if item.direction == .upload {
                    try? FileManager.default.removeItem(at: item.localURL)
                    lastUpload = UploadEvent(serverID: info.serverID, directory: RemotePath.parent(item.remotePath))
                }
            } catch {
                await client.disconnect()
                if Task.isCancelled || error is CancellationError {
                    item.state = .cancelled
                } else {
                    item.state = .failed(error.localizedDescription)
                }
                if item.direction == .download {
                    try? FileManager.default.removeItem(at: item.localURL)
                }
            }
        }
    }

    private func saveDownload(_ item: TransferItem) throws -> URL {
        if let folder = item.destinationFolder {
            return try DownloadLocation.move(item.localURL, into: folder, named: item.fileName)
        }
        let folder = Self.downloadsDirectory.appending(path: Self.safeName(item.serverName), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = Self.uniqueURL(folder.appending(path: item.fileName))
        try FileManager.default.moveItem(at: item.localURL, to: destination)
        return destination
    }

    private static func temporaryDownloadURL() -> URL {
        URL.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Server" : cleaned
    }

    /// Returns `url`, or `name (2).ext` etc. if a file already exists there.
    nonisolated static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
