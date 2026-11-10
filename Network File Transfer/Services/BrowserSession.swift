//
//  BrowserSession.swift
//  Network File Transfer
//

import Foundation
import Observation

/// A live connection used for browsing a server's files.
@Observable
final class BrowserSession {
    enum Status: Equatable {
        case connecting, connected
        case failed(String)
    }

    let info: ConnectionInfo
    private(set) var status: Status = .connecting
    private(set) var homePath = "/"
    /// Bumped whenever a directory's contents change, so visible listings reload.
    private(set) var changeCounter = 0
    private(set) var lastChangedDirectory: String?

    private let client: any FileTransferClient

    init(info: ConnectionInfo) {
        self.info = info
        self.client = ClientFactory.make(info)
    }

    /// Connects and returns the observed host key (SFTP) so the caller can remember it.
    func connect() async -> String? {
        status = .connecting
        do {
            try await client.connect()
            homePath = try await client.homeDirectory()
            status = .connected
            return await client.observedHostKey()
        } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    deinit {
        // The session is released when its server screen leaves the navigation stack.
        let client = client
        Task { await client.disconnect() }
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        try await client.list(path)
    }

    func createDirectory(named name: String, in directory: String) async throws {
        try await client.createDirectory(RemotePath.join(directory, name))
        markChanged(directory)
    }

    func delete(_ file: RemoteFile) async throws {
        try await client.delete(file)
        markChanged(RemotePath.parent(file.path))
    }

    func rename(_ file: RemoteFile, to newName: String) async throws {
        let parent = RemotePath.parent(file.path)
        try await client.rename(file.path, to: RemotePath.join(parent, newName))
        markChanged(parent)
    }

    func markChanged(_ directory: String) {
        lastChangedDirectory = directory
        changeCounter += 1
    }
}
