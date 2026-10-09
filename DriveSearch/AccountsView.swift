import ProviderKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if model.accounts.isEmpty {
                    ContentUnavailableView(
                        "No accounts",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("Add a read-only cloud account. Search keeps working offline after the first sync.")
                    )
                }
                ForEach(model.accounts) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: account.kind.symbolName)
                            Text(account.displayName)
                                .font(.headline)
                            Spacer()
                            Text(account.kind.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(statusLine(account))
                            .font(.footnote)
                            .foregroundStyle(account.status == .error || account.status == .needsSignIn ? .red : .secondary)
                        if account.kind != .protonFiles {
                            Text("\(account.itemCount) indexed items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Files app folder. Proton has no supported third-party API yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Resync") { Task { await model.resync(account.id) } }
                                .disabled(model.isWorking)
                            Button("Remove", role: .destructive) { Task { await model.remove(account.id) } }
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { adding = true }
                        .disabled(model.isWorking)
                }
            }
            .sheet(isPresented: $adding) {
                AddAccountSheet()
            }
            .overlay {
                if model.isWorking {
                    ProgressView("Working")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func statusLine(_ account: Account) -> String {
        switch account.status {
        case .idle:
            if let last = account.lastSync {
                return "Synced \(last.formatted(.relative(presentation: .named)))"
            }
            return "Not synced yet"
        case .syncing:
            return "Syncing"
        case .error:
            return account.lastError ?? "Sync failed"
        case .needsSignIn:
            return account.lastError ?? "Sign in again"
        }
    }
}

struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var nextcloudServer = ""
    @State private var s3 = S3Config.preset(named: "aws")
    @State private var s3Preset = "aws"
    @State private var accessKey = ""
    @State private var secret = ""
    @State private var pickingProton = false

    var body: some View {
        NavigationStack {
            Form {
                Section("OAuth") {
                    providerButton(.googleDrive, "Google Drive", "drive.metadata.readonly")
                    providerButton(.oneDrive, "OneDrive", "Files.Read")
                    providerButton(.dropbox, "Dropbox", "files.metadata.read and files.content.read")
                }
                Section("Nextcloud") {
                    TextField("https://cloud.example.com", text: $nextcloudServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Sign in with an app password") {
                        let server = nextcloudServer
                        Task {
                            await model.addNextcloud(serverText: server)
                            if model.statusMessage == nil { dismiss() }
                        }
                    }
                    Text("Login flow v2. The app password stays in the Keychain. Sync uses WebDAV PROPFIND and folder ETags.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("S3 and compatible") {
                    Picker("Preset", selection: $s3Preset) {
                        Text("Amazon S3").tag("aws")
                        Text("Hetzner").tag("hetzner")
                        Text("Cloudflare R2").tag("r2")
                        Text("MinIO").tag("minio")
                    }
                    .onChange(of: s3Preset) { _, preset in
                        let bucket = s3.bucket
                        let prefix = s3.prefix
                        s3 = S3Config.preset(named: preset)
                        s3.bucket = bucket
                        s3.prefix = prefix
                    }
                    TextField("Endpoint", text: endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Region", text: $s3.region)
                        .textInputAutocapitalization(.never)
                    TextField("Bucket", text: $s3.bucket)
                        .textInputAutocapitalization(.never)
                    TextField("Prefix", text: $s3.prefix)
                        .textInputAutocapitalization(.never)
                    Toggle("Path-style URLs", isOn: $s3.pathStyle)
                    TextField("Access key", text: $accessKey)
                        .textInputAutocapitalization(.never)
                    SecureField("Secret key", text: $secret)
                    Button("Add bucket") {
                        let config = s3
                        let key = accessKey
                        let secret = secret
                        Task {
                            await model.addS3(config, accessKey: key, secret: secret)
                            if model.statusMessage == nil { dismiss() }
                        }
                    }
                    Text("SigV4 ListObjectsV2. Keys are stored in the Keychain. Hetzner, R2, and MinIO are the same API with your endpoint.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Proton Drive") {
                    Button("Pick a Proton Drive folder") { pickingProton = true }
                    Text("Proton's Drive SDK is not supported for standalone third-party apps yet, and it does not ship authentication. DriveSearch indexes a folder you pick in the Files app. It does not call Proton's private API.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $pickingProton) {
                FolderPicker { url in
                    pickingProton = false
                    Task {
                        await model.addProton(url: url)
                        dismiss()
                    }
                }
            }
        }
    }

    private var endpoint: Binding<String> {
        Binding(
            get: { s3.endpoint.absoluteString },
            set: { text in
                if let url = URL(string: text), url.host != nil {
                    s3.endpoint = url
                }
            }
        )
    }

    private func providerButton(_ kind: ProviderKind, _ title: String, _ scope: String) -> some View {
        Button {
            Task {
                await model.addOAuth(kind)
                if model.statusMessage == nil { dismiss() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.clients.clientID(for: kind).isEmpty)
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
