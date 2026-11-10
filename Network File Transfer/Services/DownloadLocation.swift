//
//  DownloadLocation.swift
//  Network File Transfer
//

import Foundation
import Observation

/// Where downloads are saved: the app's own folder (visible in Files under On My iPhone),
/// or any folder the user picked in the Files app, remembered with a security-scoped bookmark.
@Observable
final class DownloadLocation {
    private static let bookmarkKey = "downloadFolderBookmark"

    /// The picked folder, or nil to use the app's own Downloads folder.
    private(set) var customFolder: URL?

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return
        }
        customFolder = url
        if isStale { remember(url) }
    }

    var displayName: String {
        customFolder?.lastPathComponent ?? "On My iPhone"
    }

    /// Saves a folder picked with `fileImporter` as the default download location.
    func setCustomFolder(_ url: URL) {
        remember(url)
        customFolder = url
    }

    func useAppFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        customFolder = nil
    }

    private func remember(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    /// Moves a finished download into `folder` (a security-scoped folder from Files),
    /// coordinating the write so file providers like iCloud Drive pick it up. Returns the final URL.
    nonisolated static func move(_ file: URL, into folder: URL, named name: String) throws -> URL {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let destination = TransferManager.uniqueURL(folder.appending(path: name))
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do {
                try FileManager.default.moveItem(at: file, to: url)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
        return destination
    }
}
