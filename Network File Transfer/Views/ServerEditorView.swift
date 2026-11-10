//
//  ServerEditorView.swift
//  Network File Transfer
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The server being edited, or nil when creating a new one.
    let server: Server?

    @State private var name = ""
    @State private var transferProtocol: TransferProtocol = .sftp
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var initialPath = ""
    @State private var color: ServerColor = .blue
    @State private var isFavorite = false
    @State private var trustedHostKey: String?

    @State private var quickConnectURL = ""
    @State private var showKeyImporter = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success
        case failure(String)
    }

    init(server: Server?, template: Server? = nil) {
        self.server = server
        guard let source = server ?? template else { return }
        let secrets = Keychain.secrets(for: source.id)
        _name = State(initialValue: server == nil ? "\(source.name) copy" : source.name)
        _transferProtocol = State(initialValue: source.transferProtocol)
        _host = State(initialValue: source.host)
        _port = State(initialValue: String(source.port))
        _username = State(initialValue: source.username)
        _authMethod = State(initialValue: source.authMethod)
        _password = State(initialValue: secrets.password)
        _privateKey = State(initialValue: secrets.privateKey)
        _passphrase = State(initialValue: secrets.passphrase)
        _initialPath = State(initialValue: source.initialPath)
        _color = State(initialValue: source.serverColor)
        _isFavorite = State(initialValue: source.isFavorite)
        _trustedHostKey = State(initialValue: server?.trustedHostKey)
    }

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port).map { (1...65535).contains($0) } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                if server == nil {
                    Section {
                        TextField("sftp://user@example.com:22/path", text: $quickConnectURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(applyQuickConnectURL)
                        Button("Fill From URL", systemImage: "wand.and.stars", action: applyQuickConnectURL)
                            .disabled(Server.parse(urlString: quickConnectURL) == nil)
                    } header: {
                        Text("Quick Setup")
                    } footer: {
                        Text("Paste a server address to fill in the fields below.")
                    }
                }

                Section("Connection") {
                    Picker("Protocol", selection: $transferProtocol) {
                        ForEach(TransferProtocol.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: transferProtocol) { old, new in
                        if port == String(old.defaultPort) { port = String(new.defaultPort) }
                        if !new.supportsKeyAuth { authMethod = .password }
                    }

                    LabeledContent("Host") {
                        TextField("example.com or 192.168.1.10", text: $host)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    LabeledContent("Port") {
                        TextField("Port", text: $port)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    LabeledContent("Name") {
                        TextField(host.isEmpty ? "Optional" : host, text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    LabeledContent("Username") {
                        TextField(transferProtocol == .ftp ? "anonymous" : "Required", text: $username)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                    }

                    if transferProtocol.supportsKeyAuth {
                        Picker("Authentication", selection: $authMethod) {
                            ForEach(AuthMethod.allCases) { Text($0.displayName).tag($0) }
                        }
                    }

                    if authMethod == .password {
                        LabeledContent("Password") {
                            SecureField("Optional", text: $password)
                                .multilineTextAlignment(.trailing)
                                .textContentType(.password)
                        }
                    } else {
                        keyFields
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Passwords and keys are stored securely in the iOS Keychain on this device.")
                }

                Section("Options") {
                    LabeledContent("Start Folder") {
                        TextField("Home", text: $initialPath)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("Favorite", isOn: $isFavorite)
                    colorPicker
                }

                if transferProtocol == .sftp, let key = trustedHostKey {
                    Section {
                        Text(key)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Button("Forget Host Key", role: .destructive) { trustedHostKey = nil }
                    } header: {
                        Text("Trusted Host Key")
                    } footer: {
                        Text("Remembered on first connect. Connections are refused if the server presents a different key.")
                    }
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            switch testState {
                            case .idle: EmptyView()
                            case .testing: ProgressView()
                            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(!isValid || testState == .testing)
                } footer: {
                    if case .failure(let message) = testState {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(server == nil ? "New Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                        .disabled(!isValid)
                }
            }
            .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.data, .text, .item]) { result in
                importKey(result)
            }
        }
    }

    @ViewBuilder
    private var keyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Private Key")
                Spacer()
                Button("Import File", systemImage: "doc.badge.plus") { showKeyImporter = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let string = UIPasteboard.general.string { privateKey = string }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            TextEditor(text: $privateKey)
                .font(.caption.monospaced())
                .frame(minHeight: 100)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .overlay(alignment: .topLeading) {
                    if privateKey.isEmpty {
                        Text("-----BEGIN OPENSSH PRIVATE KEY-----")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        LabeledContent("Passphrase") {
            SecureField("Optional", text: $passphrase)
                .multilineTextAlignment(.trailing)
        }
    }

    private var colorPicker: some View {
        HStack {
            Text("Color")
            Spacer()
            ForEach(ServerColor.allCases) { option in
                Circle()
                    .fill(option.color)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if option == color {
                            Circle().strokeBorder(.white, lineWidth: 2)
                        }
                    }
                    .onTapGesture { color = option }
                    .accessibilityLabel(option.rawValue)
                    .accessibilityAddTraits(option == color ? .isSelected : [])
            }
        }
    }

    // MARK: - Actions

    private func applyQuickConnectURL() {
        guard let parsed = Server.parse(urlString: quickConnectURL) else { return }
        transferProtocol = parsed.transferProtocol
        host = parsed.host
        port = String(parsed.port ?? parsed.transferProtocol.defaultPort)
        if let user = parsed.username { username = user }
        if let pass = parsed.password { password = pass; authMethod = .password }
        if let path = parsed.path, path != "/" { initialPath = path }
        quickConnectURL = ""
    }

    private func importKey(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            privateKey = contents
        }
    }

    private func currentInfo() -> ConnectionInfo {
        ConnectionInfo(
            serverID: server?.id ?? UUID(),
            name: name.isEmpty ? host : name,
            transferProtocol: transferProtocol,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? transferProtocol.defaultPort,
            username: username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            password: password,
            privateKey: privateKey,
            passphrase: passphrase,
            initialPath: initialPath,
            trustedHostKey: trustedHostKey
        )
    }

    private func testConnection() {
        testState = .testing
        let client = ClientFactory.make(currentInfo())
        Task {
            do {
                try await client.connect()
                _ = try await client.homeDirectory()
                if trustedHostKey == nil { trustedHostKey = await client.observedHostKey() }
                await client.disconnect()
                testState = .success
            } catch {
                await client.disconnect()
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        let target = server ?? Server()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.transferProtocol = transferProtocol
        target.host = host.trimmingCharacters(in: .whitespaces)
        target.port = Int(port) ?? transferProtocol.defaultPort
        target.username = username.trimmingCharacters(in: .whitespaces)
        target.authMethod = authMethod
        target.initialPath = initialPath.trimmingCharacters(in: .whitespaces)
        target.serverColor = color
        target.isFavorite = isFavorite
        target.trustedHostKey = transferProtocol == .sftp ? trustedHostKey : nil
        if server == nil { modelContext.insert(target) }

        Keychain.save(
            Keychain.Secrets(
                password: authMethod == .password ? password : "",
                privateKey: authMethod == .privateKey ? privateKey : "",
                passphrase: authMethod == .privateKey ? passphrase : ""
            ),
            for: target.id
        )
        dismiss()
    }
}
