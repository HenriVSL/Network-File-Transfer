//
//  FTPTransferClient.swift
//  Network File Transfer
//

import Foundation
import Network

/// A small FTP client built on Network.framework (iOS has no built-in FTP support).
/// Uses passive mode (EPSV, falling back to PASV) and binary transfers.
actor FTPTransferClient: FileTransferClient {
    private struct Reply {
        var code: Int
        var message: String
        var isPositive: Bool { (100..<400).contains(code) }
    }

    private let info: ConnectionInfo
    private var control: AsyncConnection?
    private var readBuffer = Data()
    private var supportsMLSD = true
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(info: ConnectionInfo) {
        self.info = info
    }

    func connect() async throws {
        let connection = AsyncConnection(host: info.host, port: info.port)
        do {
            try await connection.start()
        } catch {
            throw TransferError.connectionFailed(error.localizedDescription)
        }
        control = connection
        readBuffer = Data()

        try await locked {
            try expect(try await readReply(), 220)

            let user = info.username.isEmpty ? "anonymous" : info.username
            var reply = try await command("USER \(user)")
            if reply.code == 331 {
                reply = try await command("PASS \(info.password)")
            }
            guard reply.code == 230 || reply.code == 202 else {
                throw TransferError.authenticationFailed
            }
            _ = try? await command("OPTS UTF8 ON")
            try expect(try await command("TYPE I"), 200)
        }
    }

    func disconnect() async {
        if control != nil {
            _ = try? await locked { try await command("QUIT") }
        }
        control?.cancel()
        control = nil
    }

    func homeDirectory() async throws -> String {
        try await locked {
            let start = info.initialPath.trimmingCharacters(in: .whitespaces)
            if !start.isEmpty {
                try expect(try await command("CWD \(start)"), 250)
            }
            let reply = try await command("PWD")
            try expect(reply, 257)
            // 257 "/path" is the current directory
            if let first = reply.message.firstIndex(of: "\""),
               let last = reply.message.lastIndex(of: "\""), first < last {
                return String(reply.message[reply.message.index(after: first)..<last])
                    .replacingOccurrences(of: "\"\"", with: "\"")
            }
            return "/"
        }
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        try await locked {
            if supportsMLSD {
                do {
                    let data = try await dataTransfer("MLSD \(path)")
                    return Self.parseMLSD(data, directory: path)
                } catch TransferError.server(let code, _) where code >= 500 {
                    supportsMLSD = false
                }
            }
            try expect(try await command("CWD \(path)"), 250)
            let data = try await dataTransfer("LIST -a")
            return Self.parseLIST(data, directory: path)
        }
    }

    func download(_ remotePath: String, to localURL: URL, progress: ProgressHandler) async throws {
        try await locked {
            var total: Int64?
            let sizeReply = try await command("SIZE \(remotePath)")
            if sizeReply.code == 213 { total = Int64(sizeReply.message.trimmingCharacters(in: .whitespaces)) }

            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }

            let data = try await openDataConnection()
            defer { data.cancel() }
            let start = try await command("RETR \(remotePath)")
            guard start.code == 150 || start.code == 125 else { throw Self.error(start) }

            var received: Int64 = 0
            progress(0, total)
            while let chunk = try await data.receive() {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                progress(received, total)
            }
            try expect(try await readReply(), 226, 250)
        }
    }

    func upload(_ localURL: URL, to remotePath: String, progress: ProgressHandler) async throws {
        try await locked {
            let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? nil
            let handle = try FileHandle(forReadingFrom: localURL)
            defer { try? handle.close() }

            let data = try await openDataConnection()
            defer { data.cancel() }
            let start = try await command("STOR \(remotePath)")
            guard start.code == 150 || start.code == 125 else { throw Self.error(start) }

            var sent: Int64 = 0
            progress(0, total)
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try await data.send(chunk)
                sent += Int64(chunk.count)
                progress(sent, total)
            }
            try await data.finish()
            try expect(try await readReply(), 226, 250)
        }
    }

    func createDirectory(_ path: String) async throws {
        try await locked { try expect(try await command("MKD \(path)"), 257) }
    }

    func deleteFile(_ path: String) async throws {
        try await locked { try expect(try await command("DELE \(path)"), 250) }
    }

    func deleteDirectory(_ path: String) async throws {
        try await locked { try expect(try await command("RMD \(path)"), 250) }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await locked {
            try expect(try await command("RNFR \(path)"), 350)
            try expect(try await command("RNTO \(newPath)"), 250)
        }
    }

    // MARK: - Serialization

    /// FTP allows only one command at a time on the control connection, so every
    /// operation runs exclusively even though actor methods can interleave at `await`s.
    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: - Control connection

    private func command(_ line: String) async throws -> Reply {
        guard let control else { throw TransferError.notConnected }
        try await control.send(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    private func readLine() async throws -> String {
        guard let control else { throw TransferError.notConnected }
        while true {
            if let range = readBuffer.range(of: Data("\r\n".utf8)) ?? readBuffer.range(of: Data("\n".utf8)) {
                let lineData = readBuffer[readBuffer.startIndex..<range.lowerBound]
                readBuffer.removeSubrange(readBuffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            guard let chunk = try await control.receive() else {
                throw TransferError.connectionFailed("The server closed the connection.")
            }
            readBuffer.append(chunk)
        }
    }

    private func readReply() async throws -> Reply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw TransferError.protocolError("Unexpected server response: \(first)")
        }
        var message = String(first.dropFirst(4))
        // Multi-line replies start with "123-" and end with "123 "
        if first.dropFirst(3).first == "-" {
            let terminator = "\(code) "
            while true {
                let line = try await readLine()
                if line.hasPrefix(terminator) {
                    message += "\n" + line.dropFirst(4)
                    break
                }
                message += "\n" + line
            }
        }
        return Reply(code: code, message: message)
    }

    private func expect(_ reply: Reply, _ codes: Int...) throws {
        guard codes.contains(reply.code) else { throw Self.error(reply) }
    }

    private static func error(_ reply: Reply) -> TransferError {
        if reply.code == 530 { return .authenticationFailed }
        return .server(code: reply.code, message: reply.message)
    }

    // MARK: - Data connection

    private func openDataConnection() async throws -> AsyncConnection {
        var port: Int?
        let epsv = try await command("EPSV")
        if epsv.code == 229 {
            // 229 Entering Extended Passive Mode (|||6446|)
            let parts = epsv.message.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 4 { port = Int(parts[3]) }
        }
        if port == nil {
            let pasv = try await command("PASV")
            try expect(pasv, 227)
            // 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2). The host is ignored in favour
            // of the control host, which avoids issues with servers behind NAT.
            let numbers = pasv.message
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            guard numbers.count >= 6 else { throw TransferError.protocolError("Invalid PASV reply.") }
            port = numbers[numbers.count - 2] * 256 + numbers[numbers.count - 1]
        }
        guard let port else { throw TransferError.protocolError("Server did not provide a data port.") }
        let connection = AsyncConnection(host: info.host, port: port)
        try await connection.start()
        return connection
    }

    private func dataTransfer(_ line: String) async throws -> Data {
        let data = try await openDataConnection()
        defer { data.cancel() }
        let start = try await command(line)
        guard start.code == 150 || start.code == 125 else { throw Self.error(start) }
        var result = Data()
        while let chunk = try await data.receive() {
            result.append(chunk)
        }
        try expect(try await readReply(), 226, 250)
        return result
    }

    // MARK: - Listing parsers

    private static func parseMLSD(_ data: Data, directory: String) -> [RemoteFile] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"

        return String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .compactMap { line -> RemoteFile? in
                // type=file;size=123;modify=20240101120000; name
                guard let space = line.firstIndex(of: " ") else { return nil }
                let name = String(line[line.index(after: space)...])
                var facts: [String: String] = [:]
                for fact in line[..<space].split(separator: ";") {
                    let pair = fact.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
                }
                let type = facts["type"]?.lowercased() ?? "file"
                guard type != "cdir", type != "pdir", name != ".", name != ".." else { return nil }
                let kind: RemoteFile.Kind = type == "dir" ? .directory : type.contains("slink") ? .symlink : .file
                return RemoteFile(
                    name: name,
                    path: RemotePath.join(directory, name),
                    kind: kind,
                    size: facts["size"].flatMap { Int64($0) },
                    modified: facts["modify"].flatMap { formatter.date(from: String($0.prefix(14))) },
                    permissions: facts["unix.mode"]
                )
            }
    }

    private static func parseLIST(_ data: Data, directory: String) -> [RemoteFile] {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .compactMap { parseListLine($0, directory: directory) }
    }

    private static func parseListLine(_ line: String, directory: String) -> RemoteFile? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard !fields.isEmpty, !line.hasPrefix("total") else { return nil }

        // Unix: drwxr-xr-x 2 user group 4096 Jan 01 12:00 name
        if let first = fields.first?.first, "-dlbcps".contains(first), fields.count >= 9 {
            let nameStart = nthFieldIndex(in: line, 8)
            var name = String(line[nameStart...])
            let kind: RemoteFile.Kind = first == "d" ? .directory : first == "l" ? .symlink : .file
            if kind == .symlink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard name != ".", name != ".." else { return nil }
            return RemoteFile(
                name: name,
                path: RemotePath.join(directory, name),
                kind: kind,
                size: Int64(fields[4]),
                modified: parseUnixDate(month: fields[5], day: fields[6], timeOrYear: fields[7]),
                permissions: String(fields[0])
            )
        }

        // Windows/IIS: 01-15-24  03:45PM  <DIR>  name   or   01-15-24  03:45PM  1234 name
        if fields.count >= 4 {
            let nameStart = nthFieldIndex(in: line, 3)
            let name = String(line[nameStart...])
            let isDir = fields[2] == "<DIR>"
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MM-dd-yy hh:mma"
            return RemoteFile(
                name: name,
                path: RemotePath.join(directory, name),
                kind: isDir ? .directory : .file,
                size: isDir ? nil : Int64(fields[2]),
                modified: formatter.date(from: "\(fields[0]) \(fields[1])"),
                permissions: nil
            )
        }
        return nil
    }

    /// Index where the n-th whitespace-separated field starts, so names with spaces stay intact.
    private static func nthFieldIndex(in line: String, _ n: Int) -> String.Index {
        var index = line.startIndex
        var field = 0
        var inField = false
        while index < line.endIndex {
            let isSpace = line[index] == " "
            if !isSpace && !inField {
                if field == n { return index }
                field += 1
            }
            inField = !isSpace
            index = line.index(after: index)
        }
        return line.endIndex
    }

    private static func parseUnixDate(month: Substring, day: Substring, timeOrYear: Substring) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if timeOrYear.contains(":") {
            let year = Calendar.current.component(.year, from: Date())
            formatter.dateFormat = "MMM d yyyy HH:mm"
            guard let date = formatter.date(from: "\(month) \(day) \(year) \(timeOrYear)") else { return nil }
            // Dates without a year are within the last six months; roll back if it's in the future.
            return date > Date() ? Calendar.current.date(byAdding: .year, value: -1, to: date) : date
        }
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: "\(month) \(day) \(timeOrYear)")
    }
}

/// async/await wrapper around a TCP `NWConnection`.
nonisolated final class AsyncConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "AsyncConnection")

    init(host: String, port: Int) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)),
            using: .tcp
        )
    }

    func start(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    finish(.failure(TransferError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(TransferError.connectionFailed("Connection cancelled.")))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                guard !resumed else { return }
                connection.cancel()
                finish(.failure(TransferError.connectionFailed("Timed out.")))
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Signals end of data (used after uploading a file).
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Returns the next chunk of data, or nil once the peer has closed the connection.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}
