//
//  Network_File_TransferApp.swift
//  Network File Transfer
//
//  Created by Henri Lavikainen on 29.9.2026.
//

import SwiftData
import SwiftUI

@main
struct Network_File_TransferApp: App {
    @State private var transfers = TransferManager()
    @State private var downloadLocation = DownloadLocation()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(transfers)
                .environment(downloadLocation)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: Server.self)
    }
}

struct RootView: View {
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        TabView {
            Tab("Servers", systemImage: "server.rack") {
                ServerListView()
            }
            Tab("Transfers", systemImage: "arrow.up.arrow.down") {
                TransfersView()
            }
            .badge(transfers.activeCount)
            Tab("Downloads", systemImage: "arrow.down.circle") {
                DownloadsView()
            }
        }
    }
}
