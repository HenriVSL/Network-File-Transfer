//
//  FileTransferClient.swift
//  Network File Transfer
//

import Foundation

nonisolated struct RemoteFile: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case file, directory, symlink }

    var name: String
    var path: String
    var kind: Kind
    var size: Int64?
    var modified: Date?
    var permissions: String?

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
    var isHidden: Bool { name.hasPrefix(".") }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

/// Reports bytes transferred so far and the total size when known.
typealias ProgressHandler = @Sendable (_ completed: Int64, _ total: Int64?) -> Void

/// Common interface for all remote protocols. Add a new conforming type to support another protocol.
nonisolated protocol FileTransferClient: Sendable {
    func connect() async throws
    func disconnect() async
    /// The directory the session starts in (server home or configured initial path).
    func homeDirectory() async throws -> String
    func list(_ path: String) async throws -> [RemoteFile]
    func download(_ remotePath: String, to localURL: URL, progress: ProgressHandler) async throws
    func upload(_ localURL: URL, to remotePath: String, progress: ProgressHandler) async throws
    func createDirectory(_ path: String) async throws
    func deleteFile(_ path: String) async throws
    func deleteDirectory(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    /// Host key seen during connect (SFTP), so it can be remembered for next time.
    func observedHostKey() async -> String?
}

nonisolated extension FileTransferClient {
    func observedHostKey() async -> String? { nil }

    func delete(_ file: RemoteFile) async throws {
        if file.isDirectory {
            for child in try await list(file.path) {
                try await delete(child)
            }
            try await deleteDirectory(file.path)
        } else {
            try await deleteFile(file.path)
        }
    }
}

nonisolated enum TransferError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case hostKeyMismatch
    case unsupportedKey
    case server(code: Int, message: String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the server."
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .authenticationFailed: "Authentication failed. Check your username and credentials."
        case .hostKeyMismatch: "The server's host key has changed since you last connected. This could mean someone is intercepting the connection. Reset the trusted key in the server settings if the change is expected."
        case .unsupportedKey: "Unsupported private key. Use an OpenSSH-format RSA or Ed25519 key."
        case .server(let code, let message): "Server error \(code): \(message)"
        case .protocolError(let message): message
        }
    }
}

nonisolated enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty || directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

enum ClientFactory {
    static func make(_ info: ConnectionInfo) -> any FileTransferClient {
        switch info.transferProtocol {
        case .sftp: SFTPTransferClient(info: info)
        case .ftp: FTPTransferClient(info: info)
        }
    }
}
