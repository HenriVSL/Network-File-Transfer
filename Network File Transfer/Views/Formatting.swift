//
//  Formatting.swift
//  Network File Transfer
//

import SwiftUI

enum Formatting {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func icon(for file: RemoteFile) -> (name: String, color: Color) {
        switch file.kind {
        case .directory: return ("folder.fill", .accentColor)
        case .symlink: return ("link", .secondary)
        case .file: return icon(forExtension: file.fileExtension)
        }
    }

    static func icon(forExtension ext: String) -> (name: String, color: Color) {
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg":
            ("photo", .orange)
        case "mov", "mp4", "m4v", "avi", "mkv", "webm":
            ("film", .purple)
        case "mp3", "m4a", "wav", "flac", "aac", "ogg":
            ("music.note", .pink)
        case "zip", "gz", "tgz", "tar", "rar", "7z", "bz2", "xz":
            ("doc.zipper", .yellow)
        case "pdf":
            ("doc.richtext", .red)
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "kt", "php", "sh", "html", "css", "json", "xml", "yml", "yaml", "toml":
            ("chevron.left.forwardslash.chevron.right", .green)
        case "txt", "md", "log", "csv", "conf", "cfg", "ini":
            ("doc.text", .gray)
        default:
            ("doc", .gray)
        }
    }
}

struct ProtocolBadge: View {
    let transferProtocol: TransferProtocol

    var body: some View {
        Text(transferProtocol.displayName)
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: .capsule)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch transferProtocol {
        case .sftp: .green
        case .ftp: .orange
        }
    }
}
