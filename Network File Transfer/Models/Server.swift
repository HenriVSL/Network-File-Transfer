//
//  Server.swift
//  Network File Transfer
//

import Foundation
import SwiftData
import SwiftUI

nonisolated enum TransferProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case sftp
    case ftp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sftp: "SFTP"
        case .ftp: "FTP"
        }
    }

    var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftp: 21
        }
    }

    var supportsKeyAuth: Bool { self == .sftp }
}

nonisolated enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Private Key"
        }
    }
}

enum ServerColor: String, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .gray: .gray
        }
    }
}

@Model
final class Server {
    var id: UUID = UUID()
    var name: String = ""
    var protocolRaw: String = TransferProtocol.sftp.rawValue
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authRaw: String = AuthMethod.password.rawValue
    var initialPath: String = ""
    /// OpenSSH-formatted host key remembered on first connect (SFTP only).
    var trustedHostKey: String?
    var colorRaw: String = ServerColor.blue.rawValue
    var isFavorite: Bool = false
    /// Remote folder paths saved for quick access, in the order they were added.
    var bookmarks: [String] = []
    var createdAt: Date = Date()
    var lastConnectedAt: Date?

    init(name: String = "", transferProtocol: TransferProtocol = .sftp, host: String = "", port: Int? = nil, username: String = "") {
        self.id = UUID()
        self.name = name
        self.protocolRaw = transferProtocol.rawValue
        self.host = host
        self.port = port ?? transferProtocol.defaultPort
        self.username = username
    }

    var transferProtocol: TransferProtocol {
        get { TransferProtocol(rawValue: protocolRaw) ?? .sftp }
        set { protocolRaw = newValue.rawValue }
    }

    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authRaw) ?? .password }
        set { authRaw = newValue.rawValue }
    }

    var serverColor: ServerColor {
        get { ServerColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }

    var displayName: String {
        name.isEmpty ? host : name
    }

    func isBookmarked(_ path: String) -> Bool {
        bookmarks.contains(path)
    }

    func toggleBookmark(_ path: String) {
        if let index = bookmarks.firstIndex(of: path) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(path)
        }
    }

    var subtitle: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let portPart = port == transferProtocol.defaultPort ? "" : ":\(port)"
        return "\(user)\(host)\(portPart)"
    }

    /// Snapshot of everything a client needs to connect, including secrets from the Keychain.
    func connectionInfo() -> ConnectionInfo {
        let secrets = Keychain.secrets(for: id)
        return ConnectionInfo(
            serverID: id,
            name: displayName,
            transferProtocol: transferProtocol,
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username,
            authMethod: authMethod,
            password: secrets.password,
            privateKey: secrets.privateKey,
            passphrase: secrets.passphrase,
            initialPath: initialPath,
            trustedHostKey: trustedHostKey
        )
    }
}

nonisolated struct ConnectionInfo: Sendable {
    var serverID: UUID
    var name: String
    var transferProtocol: TransferProtocol
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var password: String
    var privateKey: String
    var passphrase: String
    var initialPath: String
    var trustedHostKey: String?
}

extension Server {
    /// Parses strings like `sftp://user:pass@host:2222/path` into server fields.
    struct ParsedURL {
        var transferProtocol: TransferProtocol
        var host: String
        var port: Int?
        var username: String?
        var password: String?
        var path: String?
    }

    static func parse(urlString: String) -> ParsedURL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let proto = TransferProtocol(rawValue: scheme == "ssh" ? "sftp" : scheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        return ParsedURL(
            transferProtocol: proto,
            host: host,
            port: components.port,
            username: components.user?.removingPercentEncoding,
            password: components.password?.removingPercentEncoding,
            path: components.path.isEmpty ? nil : components.path
        )
    }
}
