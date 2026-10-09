import FSearchKit
import Foundation
import ProviderKit
import QuickLook
import SwiftUI
import UIKit

struct SearchResult: Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
    var provider: ProviderKind
    var accountName: String
    var accountID: UUID
    var size: UInt64
    var modified: Date
    var kind: ItemKind
    var webURL: URL?
    var localURL: URL?
    var mirrorPath: String?
}

@MainActor
@Observable
final class AppModel {
    var accounts: [Account] = []
    var query = ""
    var results: [SearchResult] = []
    var selected: Set<UUID> = []
    var statusMessage: String?
    var quickLookURL: URL?
    var ready = false
    var isWorking = false

    let clients: OAuthClientConfig
    private let catalog: Catalog
    private let index: IndexBridge
    private let sync: SyncEngine
    private let credentials = KeychainCredentialStore()
    private let http = URLSessionHTTP()
    private var protonURLs: [UUID: URL] = [:]
    private var catalogItems: [UUID: [String: RemoteItem]] = [:]
    private var searchTask: Task<Void, Never>?
    private var bootstrapped = false
    private var foregroundInFlight = false

    init() {
        clients = ClientConfigLoader.load()
        let catalogURL = AppPaths.catalog
        if let opened = try? Catalog(databaseURL: catalogURL) {
            catalog = opened
        } else {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("drivesearch-catalog.sqlite")
            catalog = try! Catalog(databaseURL: fallback)
        }
        let index = IndexBridge(indexDirectory: AppPaths.index)
        self.index = index
        sync = SyncEngine(
            catalog: catalog,
            credentials: credentials,
            http: http,
            refresher: index,
            clients: clients,
            mirrorRoot: AppPaths.mirror
        )
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await reloadAccounts()
        restoreProtonAccess()
        do {
            try await index.setRoots(currentRoots())
        } catch {
            statusMessage = error.localizedDescription
        }
        ready = true
        await foreground()
    }

    func foreground() async {
        guard ready, !foregroundInFlight else { return }
        foregroundInFlight = true
        defer { foregroundInFlight = false }
        await sync.syncAll(maxPages: 12)
        await reloadAccounts()
        BackgroundRefresh.schedule()
        await runSearch(query)
    }

    func backgroundSync() async {
        guard ready else { return }
        await sync.syncAll(maxPages: 8)
        await reloadAccounts()
        BackgroundRefresh.schedule()
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            await runSearch(text)
        }
    }

    func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        scheduleSearch()
    }

    func clearSelection() {
        selected.removeAll()
        scheduleSearch()
    }

    func open(_ result: SearchResult) async {
        if result.provider == .protonFiles || result.provider == .s3 {
            await download(result)
            return
        }
        if let url = result.webURL {
            await UIApplication.shared.open(url)
            return
        }
        await download(result)
    }

    func download(_ result: SearchResult) async {
        if let local = result.localURL {
            quickLookURL = local
            return
        }
        guard
            let account = accounts.first(where: { $0.id == result.accountID }),
            let mirrorPath = result.mirrorPath,
            let item = catalogItems[account.id]?[mirrorPath],
            let creds = try? credentials.load(account.id),
            let request = try? Providers.make(account.kind).downloadRequest(item: item, account: account, credentials: creds)
        else {
            statusMessage = "Nothing to download. Google Drive's metadata scope opens the file in the browser instead."
            if let url = result.webURL { await UIApplication.shared.open(url) }
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let (temp, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                statusMessage = "The download was rejected."
                return
            }
            let destination = AppPaths.quickLook.appendingPathComponent(result.name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            quickLookURL = destination
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addOAuth(_ kind: ProviderKind) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let creds = try await OAuthCoordinator.shared.signIn(kind: kind, clients: clients, http: http)
            let account = Account(kind: kind, displayName: kind.title, config: config(for: kind))
            try credentials.save(account.id, creds)
            try await catalog.upsertAccount(account)
            try FileManager.default.createDirectory(
                at: AppPaths.mirror.appendingPathComponent(account.id.uuidString, isDirectory: true),
                withIntermediateDirectories: true
            )
            await reloadAccounts()
            try await sync.sync(accountID: account.id, maxPages: 80)
            await reloadAccounts()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addNextcloud(serverText: String) async {
        isWorking = true
        defer { isWorking = false }
        guard let server = normalizedServer(serverText) else {
            statusMessage = "Enter the Nextcloud server URL, including https."
            return
        }
        do {
            guard let start = Nextcloud.loginStartRequest(server: server) else {
                throw ProviderError.parse("That server URL is not usable.")
            }
            let challenge = try Nextcloud.parseLoginStart(try HTTP.require(try await http.send(start)))
            await UIApplication.shared.open(challenge.login)
            let deadline = Date().addingTimeInterval(5 * 60)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                let polled = try await http.send(Nextcloud.loginPollRequest(challenge))
                guard let success = try Nextcloud.parseLoginPoll(polled) else { continue }
                let account = Account(
                    kind: .nextcloud,
                    displayName: success.server.host ?? "Nextcloud",
                    config: .nextcloud(server: success.server, username: success.username)
                )
                try credentials.save(account.id, .basic(username: success.username, secret: success.appPassword))
                try await catalog.upsertAccount(account)
                try FileManager.default.createDirectory(
                    at: AppPaths.mirror.appendingPathComponent(account.id.uuidString, isDirectory: true),
                    withIntermediateDirectories: true
                )
                await reloadAccounts()
                try await sync.sync(accountID: account.id, maxPages: 4)
                await reloadAccounts()
                return
            }
            statusMessage = "Nextcloud sign-in timed out."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addS3(_ config: S3Config, accessKey: String, secret: String) async {
        guard !config.bucket.isEmpty, !accessKey.isEmpty, !secret.isEmpty else {
            statusMessage = "Bucket, access key, and secret are required."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let account = Account(kind: .s3, displayName: config.bucket, config: .s3(config))
            try credentials.save(account.id, .s3(accessKeyID: accessKey, secretAccessKey: secret))
            try await catalog.upsertAccount(account)
            try FileManager.default.createDirectory(
                at: AppPaths.mirror.appendingPathComponent(account.id.uuidString, isDirectory: true),
                withIntermediateDirectories: true
            )
            await reloadAccounts()
            try await sync.sync(accountID: account.id, maxPages: 40)
            await reloadAccounts()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addProton(url: URL) async {
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = url.startAccessingSecurityScopedResource()
            let account = Account(
                kind: .protonFiles,
                displayName: url.lastPathComponent,
                config: .proton(folderName: url.lastPathComponent, bookmark: bookmark)
            )
            protonURLs[account.id] = url
            try await catalog.upsertAccount(account)
            try await index.setRoots(currentRoots())
            await reloadAccounts()
            try? await index.refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func resync(_ id: UUID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await sync.sync(accountID: id, maxPages: 80)
            await reloadAccounts()
            await runSearch(query)
        } catch {
            statusMessage = error.localizedDescription
            await reloadAccounts()
        }
    }

    func remove(_ id: UUID) async {
        if let url = protonURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
        do {
            try await sync.remove(accountID: id)
            await reloadAccounts()
            try await index.setRoots(currentRoots())
            await runSearch(query)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func reloadAccounts() async {
        accounts = (try? await catalog.accounts()) ?? []
        var next: [UUID: [String: RemoteItem]] = [:]
        for account in accounts {
            let rows = (try? await catalog.items(account: account.id)) ?? []
            var byMirror: [String: RemoteItem] = [:]
            for row in rows {
                byMirror[row.mirrorPath] = row
            }
            next[account.id] = byMirror
        }
        catalogItems = next
    }

    private func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        let universe = accounts.compactMap { scopeURL($0)?.resolvingSymlinksInPath().path }
        let restricted = selected.isEmpty ? nil : accounts.filter { selected.contains($0.id) }.compactMap { scopeURL($0)?.resolvingSymlinksInPath().path }
        let queries = QueryComposer.fsearchQueries(userText: trimmed, universe: universe, restrictTo: restricted)
        do {
            var hits: [FSearchHit] = []
            for item in queries {
                hits.append(contentsOf: try await index.search(query: item, limit: 50))
            }
            results = map(hits)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func map(_ hits: [FSearchHit]) -> [SearchResult] {
        let mirror = AppPaths.mirror.resolvingSymlinksInPath().path
        var seen = Set<String>()
        var output: [SearchResult] = []
        for hit in hits.sorted(by: { $0.score > $1.score }) {
            guard seen.insert(hit.path).inserted else { continue }
            guard let result = makeResult(hit, mirrorRoot: mirror) else { continue }
            if !selected.isEmpty, !selected.contains(result.accountID) { continue }
            output.append(result)
            if output.count == 80 { break }
        }
        return output
    }

    private func makeResult(_ hit: FSearchHit, mirrorRoot: String) -> SearchResult? {
        if hit.path == mirrorRoot { return nil }
        if hit.path.hasPrefix(mirrorRoot + "/") {
            let rest = String(hit.path.dropFirst(mirrorRoot.count + 1))
            let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard let idText = parts.first, let accountID = UUID(uuidString: String(idText)),
                  let account = accounts.first(where: { $0.id == accountID }) else { return nil }
            let mirrorPath = parts.count > 1 ? String(parts[1]) : ""
            if mirrorPath.isEmpty { return nil }
            let item = catalogItems[accountID]?[mirrorPath]
            let web = item.flatMap { $0.webURL ?? Providers.make(account.kind).browserURL(item: $0, account: account) }
            return SearchResult(
                id: hit.path,
                name: item?.name ?? hit.name,
                path: item?.relativePath ?? mirrorPath,
                provider: account.kind,
                accountName: account.displayName,
                accountID: accountID,
                size: hit.size,
                modified: hit.modified,
                kind: (item?.kind ?? (hit.kind == .dir ? .folder : .file)),
                webURL: web,
                localURL: nil,
                mirrorPath: mirrorPath
            )
        }
        for (accountID, url) in protonURLs {
            let root = url.resolvingSymlinksInPath().path
            guard hit.path == root || hit.path.hasPrefix(root + "/") else { continue }
            if hit.path == root { return nil }
            guard let account = accounts.first(where: { $0.id == accountID }) else { continue }
            let relative = String(hit.path.dropFirst(root.count + 1))
            return SearchResult(
                id: hit.path,
                name: hit.name,
                path: relative,
                provider: .protonFiles,
                accountName: account.displayName,
                accountID: accountID,
                size: hit.size,
                modified: hit.modified,
                kind: hit.kind == .dir ? .folder : .file,
                webURL: nil,
                localURL: URL(fileURLWithPath: hit.path),
                mirrorPath: nil
            )
        }
        return nil
    }

    private func scopeURL(_ account: Account) -> URL? {
        switch account.config {
        case .proton:
            protonURLs[account.id]
        case .google, .oneDrive, .dropbox, .nextcloud, .s3:
            AppPaths.mirror.appendingPathComponent(account.id.uuidString, isDirectory: true)
        }
    }

    private func currentRoots() -> [URL] {
        var roots = [AppPaths.mirror]
        roots.append(contentsOf: protonURLs.values)
        return roots
    }

    private func restoreProtonAccess() {
        for account in accounts {
            guard case .proton(_, let bookmark) = account.config else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            protonURLs[account.id] = url
        }
    }

    private func config(for kind: ProviderKind) -> AccountConfig {
        switch kind {
        case .googleDrive: .google
        case .oneDrive: .oneDrive
        case .dropbox: .dropbox
        case .nextcloud: .nextcloud(server: URL(string: "https://example.invalid")!, username: "")
        case .s3: .s3(S3Config.preset(named: "aws"))
        case .protonFiles: .proton(folderName: "", bookmark: Data())
        }
    }

    private func normalizedServer(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme, scheme == "https" || scheme == "http", url.host != nil else {
            return nil
        }
        return url
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
