import Foundation

public protocol CloudProvider: Sendable {
    var kind: ProviderKind { get }
    func authorizationURL(config: OAuthClientConfig, challenge: String, state: String) throws -> URL
    func exchange(code: String, config: OAuthClientConfig, verifier: String, http: HTTPSending) async throws -> Credentials
    func pull(
        account: Account,
        credentials: Credentials,
        config: OAuthClientConfig,
        http: HTTPSending
    ) async throws -> (page: SyncPage, credentials: Credentials)
    func browserURL(item: RemoteItem, account: Account) -> URL?
    func downloadRequest(item: RemoteItem, account: Account, credentials: Credentials) throws -> URLRequest?
}

public enum Providers {
    public static func make(_ kind: ProviderKind) -> any CloudProvider {
        switch kind {
        case .googleDrive: GoogleDriveProvider()
        case .oneDrive: OneDriveProvider()
        case .dropbox: DropboxProvider()
        case .nextcloud: NextcloudProvider()
        case .s3: S3Provider()
        case .protonFiles: ProtonFilesProvider()
        }
    }
}

/// Proton Drive has no supported standalone API yet. This provider indexes a folder
/// the user picked in the Files app. The engine walks that bookmark; there is no network sync.
struct ProtonFilesProvider: CloudProvider, Sendable {
    let kind: ProviderKind = .protonFiles

    func authorizationURL(config: OAuthClientConfig, challenge: String, state: String) throws -> URL {
        throw ProviderError.notConfigured("Proton Drive is added by picking a folder in the Files app.")
    }

    func exchange(code: String, config: OAuthClientConfig, verifier: String, http: HTTPSending) async throws -> Credentials {
        throw ProviderError.notConfigured("Proton Drive is added by picking a folder in the Files app.")
    }

    func pull(
        account: Account,
        credentials: Credentials,
        config: OAuthClientConfig,
        http: HTTPSending
    ) async throws -> (page: SyncPage, credentials: Credentials) {
        let page = SyncPage(cursor: SyncCursor(phase: "proton.files"), hasMore: false)
        return (page, .none)
    }

    func browserURL(item: RemoteItem, account: Account) -> URL? { nil }

    func downloadRequest(item: RemoteItem, account: Account, credentials: Credentials) throws -> URLRequest? { nil }
}

public protocol SearchRefreshing: Sendable {
    func refresh() async throws
}

public actor SyncEngine {
    private let catalog: Catalog
    private let credentials: any CredentialStoring
    private let http: any HTTPSending
    private let refresher: any SearchRefreshing
    private let clients: OAuthClientConfig
    private let mirrorRoot: URL

    public init(
        catalog: Catalog,
        credentials: any CredentialStoring,
        http: any HTTPSending,
        refresher: any SearchRefreshing,
        clients: OAuthClientConfig,
        mirrorRoot: URL
    ) {
        self.catalog = catalog
        self.credentials = credentials
        self.http = http
        self.refresher = refresher
        self.clients = clients
        self.mirrorRoot = mirrorRoot
    }

    public func sync(accountID: UUID, maxPages: Int = 40) async throws {
        guard var account = try await catalog.account(accountID) else { return }
        if account.kind == .protonFiles {
            try await refresher.refresh()
            try await catalog.setSyncState(accountID, status: .idle, error: nil, lastSync: Date(), cursor: account.cursor, replaceGeneration: nil)
            return
        }
        guard var creds = try credentials.load(accountID) else {
            try await catalog.setSyncState(accountID, status: .needsSignIn, error: "Sign in again.", lastSync: nil, cursor: account.cursor, replaceGeneration: account.replaceGeneration)
            return
        }
        try await catalog.setSyncState(accountID, status: .syncing, error: nil, lastSync: nil, cursor: account.cursor, replaceGeneration: account.replaceGeneration)
        let provider = Providers.make(account.kind)
        var pages = 0
        do {
            while pages < maxPages {
                let pulled = try await provider.pull(account: account, credentials: creds, config: clients, http: http)
                creds = pulled.credentials
                try credentials.save(accountID, creds)
                let page = pulled.page
                if page.beginsReplacement {
                    account.replaceGeneration = (account.replaceGeneration ?? 0) + 1
                }
                let generation = account.replaceGeneration ?? 0
                if !page.upserts.isEmpty {
                    try await catalog.upsertItems(account: accountID, page.upserts, generation: generation)
                }
                if !page.deletions.isEmpty {
                    try await catalog.deleteItems(
                        account: accountID,
                        remoteIDs: page.deletions.compactMap(\.remoteID),
                        relativePaths: page.deletions.compactMap(\.relativePath)
                    )
                }
                if !page.refreshedChildren.isEmpty {
                    let existing = try await catalog.items(account: accountID)
                    var stale: [String] = []
                    for item in existing {
                        guard let parent = item.parentRemoteID, let live = page.refreshedChildren[parent] else { continue }
                        if !live.contains(item.remoteID) { stale.append(item.remoteID) }
                    }
                    if !stale.isEmpty {
                        try await catalog.deleteItems(account: accountID, remoteIDs: stale, relativePaths: [])
                    }
                }
                account.cursor = page.cursor
                if let name = page.accountName, !name.isEmpty { account.displayName = name }
                if page.endsReplacement, let generation = account.replaceGeneration {
                    try await catalog.deleteStale(account: accountID, keeping: generation)
                }
                var stored = try await catalog.items(account: accountID)
                let finishedPage = !page.hasMore
                if account.kind == .googleDrive, !page.deferMirror {
                    GoogleDrive.resolvePaths(&stored)
                }
                if !page.deferMirror {
                    PathSanitizer.assign(&stored)
                    try await catalog.replaceItems(account: accountID, stored, generation: generation)
                    let root = mirrorRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
                    try MetadataMirror.apply(accountRoot: root, items: stored)
                }
                account.itemCount = (try? await catalog.account(accountID))?.itemCount ?? stored.count
                account.status = .syncing
                account.lastError = nil
                try await catalog.upsertAccount(account)
                pages += 1
                if finishedPage { break }
            }
            try await refresher.refresh()
            account.status = .idle
            account.lastError = nil
            if account.cursor?.phase != "google.list"
                && account.cursor?.phase != "onedrive.page"
                && account.cursor?.phase != "dropbox.page"
                && account.cursor?.phase != "s3.page" {
                account.lastSync = Date()
            }
            account.itemCount = try await catalog.items(account: accountID).count
            try await catalog.upsertAccount(account)
        } catch let error as ProviderError {
            let status: SyncStatus
            switch error {
            case .unauthorized:
                status = .needsSignIn
            case .notConfigured, .http, .parse, .invalidPath, .transport:
                status = .error
            }
            account.status = status
            account.lastError = error.localizedDescription
            try? await catalog.upsertAccount(account)
            throw error
        } catch {
            account.status = .error
            account.lastError = error.localizedDescription
            try? await catalog.upsertAccount(account)
            throw error
        }
    }

    public func remove(accountID: UUID) async throws {
        try credentials.delete(accountID)
        try await catalog.deleteAccount(accountID)
        let root = mirrorRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try await refresher.refresh()
    }

    public func syncAll(maxPages: Int = 20) async {
        let known = (try? await catalog.accounts()) ?? []
        for account in known {
            try? await sync(accountID: account.id, maxPages: maxPages)
        }
    }
}
