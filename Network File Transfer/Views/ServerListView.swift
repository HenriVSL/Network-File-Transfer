//
//  ServerListView.swift
//  Network File Transfer
//

import SwiftData
import SwiftUI

struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.name) private var servers: [Server]

    @State private var searchText = ""
    @State private var editorTarget: EditorTarget?
    @State private var serverToDelete: Server?
    @State private var router = NavigationRouter()

    enum EditorTarget: Identifiable {
        case new
        case edit(Server)
        case duplicate(Server)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let server): "edit-\(server.id)"
            case .duplicate(let server): "dup-\(server.id)"
            }
        }
    }

    private var filtered: [Server] {
        guard !searchText.isEmpty else { return servers }
        return servers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.host.localizedCaseInsensitiveContains(searchText)
                || $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var favorites: [Server] { filtered.filter(\.isFavorite) }

    private var recent: [Server] {
        filtered
            .filter { !$0.isFavorite && $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(3)
            .map { $0 }
    }

    private var others: [Server] {
        let shown = Set((favorites + recent).map(\.id))
        return filtered.filter { !shown.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if servers.isEmpty {
                    emptyState
                } else {
                    List {
                        section("Favorites", favorites)
                        section("Recent", recent)
                        section(favorites.isEmpty && recent.isEmpty ? "Servers" : "All Servers", others)
                    }
                    .searchable(text: $searchText, prompt: "Search servers")
                }
            }
            .navigationTitle("Servers")
            .navigationDestination(for: Server.self) { server in
                SessionView(server: server)
            }
            .environment(router)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") {
                        editorTarget = .new
                    }
                }
            }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .new: ServerEditorView(server: nil)
                case .edit(let server): ServerEditorView(server: server)
                case .duplicate(let server): ServerEditorView(server: nil, template: server)
                }
            }
            .confirmationDialog(
                "Delete \(serverToDelete?.displayName ?? "server")?",
                isPresented: Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let server = serverToDelete { delete(server) }
                }
            } message: {
                Text("The saved server and its credentials will be removed from this device.")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ servers: [Server]) -> some View {
        if !servers.isEmpty {
            Section(title) {
                ForEach(servers) { server in
                    NavigationLink(value: server) {
                        ServerRow(server: server)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            serverToDelete = server
                        }
                        Button("Edit", systemImage: "pencil") {
                            editorTarget = .edit(server)
                        }
                        .tint(.gray)
                    }
                    .swipeActions(edge: .leading) {
                        Button(server.isFavorite ? "Unfavorite" : "Favorite", systemImage: server.isFavorite ? "star.slash" : "star") {
                            server.isFavorite.toggle()
                        }
                        .tint(.yellow)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editorTarget = .edit(server) }
                        if !server.bookmarks.isEmpty {
                            Menu("Open Bookmark", systemImage: "bookmark") {
                                ForEach(server.bookmarks, id: \.self) { path in
                                    Button {
                                        router.open(server, at: path)
                                    } label: {
                                        Label(DirectoryRoute.displayName(for: path), systemImage: "folder")
                                        Text(path)
                                    }
                                }
                            }
                        }
                        Button("Duplicate", systemImage: "plus.square.on.square") { editorTarget = .duplicate(server) }
                        Button(server.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                            server.isFavorite.toggle()
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { serverToDelete = server }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
        } description: {
            Text("Save an SFTP or FTP server to browse, upload and download files.")
        } actions: {
            Button("Add Server") { editorTarget = .new }
                .buttonStyle(.borderedProminent)
        }
    }

    private func delete(_ server: Server) {
        Keychain.deleteAll(for: server.id)
        modelContext.delete(server)
        serverToDelete = nil
    }
}

struct ServerRow: View {
    let server: Server

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: server.transferProtocol == .sftp ? "lock.shield.fill" : "externaldrive.fill.badge.wifi")
                .font(.title3)
                .foregroundStyle(server.serverColor.color)
                .frame(width: 42, height: 42)
                .background(server.serverColor.color.opacity(0.18), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if server.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(server.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            ProtocolBadge(transferProtocol: server.transferProtocol)
        }
        .padding(.vertical, 4)
    }
}
