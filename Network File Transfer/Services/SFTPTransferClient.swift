//
//  SFTPTransferClient.swift
//  Network File Transfer
//

import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

actor SFTPTransferClient: FileTransferClient {
    private let info: ConnectionInfo
    private var ssh: SSHClient?
    private var sftp: SFTPClient?
    private let hostKeyRecorder: HostKeyValidator

    private static let chunkSize = 32 * 1024

    init(info: ConnectionInfo) {
        self.info = info
        self.hostKeyRecorder = HostKeyValidator(trustedKey: info.trustedHostKey)
    }

    func connect() async throws {
        let auth = try authenticationMethod()
        do {
            let ssh = try await SSHClient.connect(
                host: info.host,
                port: info.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(hostKeyRecorder),
                reconnect: .never,
                connectTimeout: .seconds(15)
            )
            self.ssh = ssh
            self.sftp = try await ssh.openSFTP()
        } catch is AuthenticationFailed {
            throw TransferError.authenticationFailed
        } catch is HostKeyMismatchError {
            throw TransferError.hostKeyMismatch
        } catch let error as TransferError {
            throw error
        } catch {
            throw TransferError.connectionFailed(String(describing: error))
        }
    }

    func disconnect() async {
        try? await sftp?.close()
        try? await ssh?.close()
        sftp = nil
        ssh = nil
    }

    func observedHostKey() async -> String? {
        hostKeyRecorder.observedKey
    }

    func homeDirectory() async throws -> String {
        let sftp = try client()
        let start = info.initialPath.trimmingCharacters(in: .whitespaces)
        return try await sftp.getRealPath(atPath: start.isEmpty ? "." : start)
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        let sftp = try client()
        let names = try await sftp.listDirectory(atPath: path)
        return names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                let attrs = component.attributes
                return RemoteFile(
                    name: component.filename,
                    path: RemotePath.join(path, component.filename),
                    kind: Self.kind(permissions: attrs.permissions, longname: component.longname),
                    size: attrs.size.map { Int64($0) },
                    modified: attrs.accessModificationTime?.modificationTime,
                    permissions: component.longname.split(separator: " ").first.map(String.init)
                )
            }
    }

    func download(_ remotePath: String, to localURL: URL, progress: ProgressHandler) async throws {
        let sftp = try client()
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
            let total = try? await file.readAttributes().size.map { Int64($0) }
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }

            var offset: UInt64 = 0
            progress(0, total)
            while true {
                try Task.checkCancellation()
                let buffer = try await file.read(from: offset, length: UInt32(Self.chunkSize))
                if buffer.readableBytes == 0 { break }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(buffer.readableBytes)
                progress(Int64(offset), total)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func upload(_ localURL: URL, to remotePath: String, progress: ProgressHandler) async throws {
        let sftp = try client()
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? nil
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        do {
            var offset: UInt64 = 0
            progress(0, total)
            while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                progress(Int64(offset), total)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func createDirectory(_ path: String) async throws {
        try await client().createDirectory(atPath: path)
    }

    func deleteFile(_ path: String) async throws {
        try await client().remove(at: path)
    }

    func deleteDirectory(_ path: String) async throws {
        try await client().rmdir(at: path)
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await client().rename(at: path, to: newPath)
    }

    // MARK: - Helpers

    private func client() throws -> SFTPClient {
        guard let sftp else { throw TransferError.notConnected }
        return sftp
    }

    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        switch info.authMethod {
        case .password:
            return .passwordBased(username: info.username, password: info.password)
        case .privateKey:
            let key = info.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let passphrase = info.passphrase.isEmpty ? nil : Data(info.passphrase.utf8)
            do {
                switch try SSHKeyDetection.detectPrivateKeyType(from: key) {
                case .ed25519:
                    return .ed25519(username: info.username, privateKey: try .init(sshEd25519: key, decryptionKey: passphrase))
                case .rsa:
                    return .rsa(username: info.username, privateKey: try .init(sshRsa: key, decryptionKey: passphrase))
                default:
                    throw TransferError.unsupportedKey
                }
            } catch {
                throw TransferError.unsupportedKey
            }
        }
    }

    private static func kind(permissions: UInt32?, longname: String) -> RemoteFile.Kind {
        if let permissions {
            switch permissions & 0o170000 {
            case 0o040000: return .directory
            case 0o120000: return .symlink
            default: return .file
            }
        }
        switch longname.first {
        case "d": return .directory
        case "l": return .symlink
        default: return .file
        }
    }
}

nonisolated struct HostKeyMismatchError: Error {}

/// Trust-on-first-use host key validation: accepts an unknown key (and records it),
/// but rejects a key that differs from the one remembered for this server.
nonisolated final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trustedKey: String?
    private let lock = NSLock()
    private var _observedKey: String?

    var observedKey: String? {
        lock.withLock { _observedKey }
    }

    init(trustedKey: String?) {
        self.trustedKey = trustedKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        lock.withLock { _observedKey = key }
        if let trustedKey, !trustedKey.isEmpty, trustedKey != key {
            validationCompletePromise.fail(HostKeyMismatchError())
        } else {
            validationCompletePromise.succeed(())
        }
    }
}
