# Network File Transfer

An SFTP and FTP client for iPhone and iPad, built with SwiftUI. Save your
servers, browse their folders, and upload or download files. Transfers can
keep running after you leave the app.

## Features

### Servers

| | |
|---|---|
| **SFTP and FTP** | SFTP over SSH (default port 22) and plain FTP (default port 21) |
| **Authentication** | Password, or for SFTP an OpenSSH-format RSA or Ed25519 private key with an optional passphrase. Keys can be pasted or imported from Files. FTP falls back to `anonymous` when no username is set |
| **Secure storage** | Passwords, keys and passphrases are kept in the iOS Keychain on this device only. Other server details are stored with SwiftData |
| **Host key check** | SFTP remembers the server's host key on first connect and refuses to connect if it changes later. The key can be viewed and forgotten in the server settings |
| **Quick setup** | Paste a URL such as `sftp://user@example.com:2222/path` (also `ssh://` and `ftp://`) to fill in the form |
| **Test Connection** | Check the settings before saving |
| **Organisation** | Favourites, the 3 most recently used servers, search, a colour per server, duplicate, and a start folder |
| **Bookmarks** | Bookmark remote folders per server and open them straight from the server list's context menu |

### Browsing

| | |
|---|---|
| **Folder listing** | Name, size and modification date, where the server provides them |
| **Sort and filter** | Sort by name, date modified or size, filter the current folder, and show or hide hidden files |
| **File operations** | Create folders, rename, delete (folders are deleted recursively), and copy a file's remote path |
| **Multi-select** | Select several items to download or delete them together |
| **Upload** | Upload one or more files picked in the Files app |
| **Download** | Download to the app's own folder, or use **Download To...** to save into any folder you pick in Files |

### Transfers and downloads

| | |
|---|---|
| **Transfers tab** | Live progress for each upload and download, with cancel, retry and **Clear Finished**. The tab badge shows how many are active |
| **Background transfers** | Transfers keep running after the app leaves the foreground, with progress shown by the system (iOS 26 continued processing tasks) |
| **Downloads tab** | Browse downloaded files, preview them with Quick Look, share or delete them |
| **Save location** | Choose the default download folder: the app's own folder or any folder in Files, including iCloud Drive |
| **Files app** | The app's folder appears in Files under **On My iPhone > Network File Transfer**. Downloads are grouped in a subfolder per server, and name clashes get a ` (2)`, ` (3)`, ... suffix |

## How it works

- Both protocols implement a shared `FileTransferClient` protocol
  ([`Services/FileTransferClient.swift`](Network%20File%20Transfer/Services/FileTransferClient.swift)),
  so a new protocol only needs one more conforming type.
- **SFTP** uses [Citadel](https://github.com/orlandos-nl/Citadel), built on
  SwiftNIO SSH. Files are read and written in 32 KB chunks.
- **FTP** is a small client written on Apple's Network framework, since iOS
  has no built-in FTP support. It uses passive mode (EPSV, falling back to
  PASV) and binary transfers. It lists folders with `MLSD` and falls back to
  parsing Unix- and Windows-style `LIST` output.
- Each transfer opens its own connection, so browsing stays responsive while
  files move. Downloads go to a temporary file first and are moved into place
  when complete.
- Background work uses `beginBackgroundTask` together with
  `BGContinuedProcessingTask`, which iOS can show and let you stop from the
  system UI.

**Note:** FTP is unencrypted. The username, password and file contents are
sent in plain text. Use SFTP wherever you can. FTPS is not supported.

## Requirements

- iOS / iPadOS 26.2 or later
- Local Network permission, to reach servers on your own network (iOS asks
  on first use)

## Install

1. Download the unsigned `.ipa` from the
   [latest release](https://github.com/HenriVSL/Network-File-Transfer/releases/latest).
2. Sideload it with a tool that re-signs it with your own Apple ID, such as
   [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or
   [Sideloadly](https://sideloadly.io).

Apps signed with a free Apple ID expire after 7 days and need to be re-signed.

## Build from source

1. Open `Network File Transfer.xcodeproj` in Xcode 26.2 or later.
2. Select your team under **Signing & Capabilities** for the
   `Network File Transfer` target. Change the bundle identifier
   (`henril.Network-File-Transfer`) if Xcode reports a conflict.
3. Build and run. Xcode resolves the Swift packages on first open.

The custom Info.plist keys (file sharing, background task identifiers) are in
[`Config/Info.plist`](Config/Info.plist).

## Third-party components

Swift packages used by the app (versions from `Package.resolved`):

| Package | Licence |
|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | MIT |
| [swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh) (fork of [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh), used by Citadel) | Apache 2.0 |
| [BigInt](https://github.com/attaswift/BigInt) | MIT |
| [swift-nio](https://github.com/apple/swift-nio), [swift-crypto](https://github.com/apple/swift-crypto), [swift-log](https://github.com/apple/swift-log), [swift-asn1](https://github.com/apple/swift-asn1), [swift-atomics](https://github.com/apple/swift-atomics), [swift-collections](https://github.com/apple/swift-collections), [swift-system](https://github.com/apple/swift-system) | Apache 2.0 |

## License

MIT, see [LICENSE](LICENSE).
