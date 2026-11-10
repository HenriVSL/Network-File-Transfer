//
//  SessionView.swift
//  Network File Transfer
//

import Observation
import SwiftUI

/// Connects to a server and shows its home directory. Subfolders are pushed onto the
/// same navigation stack as `DirectoryView`s sharing this session.
struct SessionView: View {
    let server: Server

    @State private var session: BrowserSession?

    var body: some View {
        directory(path: nil, title: server.displayName)
            .navigationDestination(for: DirectoryRoute.self) { route in
                directory(path: route.path, title: route.name)
            }
    }

    /// A folder listing once connected, or the connection state. Every screen triggers the
    /// connection, because opening a bookmark pushes a folder before this view has appeared.
    /// A nil `path` means the session's home directory.
    private func directory(path: String?, title: String) -> some View {
        Group {
            if let session {
                switch session.status {
                case .connecting:
                    ProgressView("Connecting to \(server.displayName)…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Connect", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await connect(session) } }
                            .buttonStyle(.borderedProminent)
                    }
                case .connected:
                    DirectoryView(path: path ?? session.homePath, title: title)
                        .environment(session)
                        .environment(server)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .task {
            guard session == nil else { return }
            let newSession = BrowserSession(info: server.connectionInfo())
            session = newSession
            await connect(newSession)
        }
    }

    private func connect(_ session: BrowserSession) async {
        if let key = await session.connect() {
            if server.trustedHostKey == nil { server.trustedHostKey = key }
        }
        if session.status == .connected {
            server.lastConnectedAt = Date()
        }
    }
}

struct DirectoryRoute: Hashable {
    var path: String
    var name: String

    init(path: String, name: String? = nil) {
        self.path = path
        self.name = name ?? Self.displayName(for: path)
    }

    static func displayName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}

/// Holds the Servers tab's navigation path so any screen can jump to a server or folder.
@Observable
final class NavigationRouter {
    var path = NavigationPath()

    func open(_ server: Server, at folder: String? = nil) {
        path = NavigationPath()
        path.append(server)
        if let folder { path.append(DirectoryRoute(path: folder)) }
    }

    func open(folder: String) {
        path.append(DirectoryRoute(path: folder))
    }
}
