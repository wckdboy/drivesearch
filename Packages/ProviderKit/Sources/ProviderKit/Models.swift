import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Equatable {
    case googleDrive
    case oneDrive
    case dropbox
    case nextcloud
    case s3
    case protonFiles

    public var title: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        case .nextcloud: "Nextcloud"
        case .s3: "S3"
        case .protonFiles: "Proton Drive"
        }
    }

    /// OAuth providers need a client id from Secrets.xcconfig. Nextcloud, S3, and Proton do not.
    public var usesOAuthClient: Bool {
        switch self {
        case .googleDrive, .oneDrive, .dropbox: true
        case .nextcloud, .s3, .protonFiles: false
        }
    }

    public var symbolName: String {
        switch self {
        case .googleDrive: "g.circle"
        case .oneDrive: "cloud"
        case .dropbox: "shippingbox"
        case .nextcloud: "server.rack"
        case .s3: "externaldrive"
        case .protonFiles: "lock.shield"
        }
    }
}

public enum ItemKind: String, Codable, Sendable, Equatable {
    case file
    case folder
}

public struct RemoteItem: Codable, Equatable, Sendable, Identifiable {
    public var remoteID: String
    public var parentRemoteID: String?
    public var name: String
    /// Path inside the account, using `/`, without a leading slash.
    public var relativePath: String
    /// Path of the on-disk stub, relative to the account mirror directory.
    public var mirrorPath: String
    public var size: UInt64
    public var modified: Date
    public var kind: ItemKind
    public var etag: String?
    public var webURL: URL?

    public var id: String { remoteID }

    public init(
        remoteID: String,
        parentRemoteID: String? = nil,
        name: String,
        relativePath: String,
        mirrorPath: String? = nil,
        size: UInt64,
        modified: Date,
        kind: ItemKind,
        etag: String? = nil,
        webURL: URL? = nil
    ) {
        self.remoteID = remoteID
        self.parentRemoteID = parentRemoteID
        self.name = name
        self.relativePath = relativePath
        self.mirrorPath = mirrorPath ?? relativePath
        self.size = size
        self.modified = modified
        self.kind = kind
        self.etag = etag
        self.webURL = webURL
    }
}

public struct SyncCursor: Codable, Equatable, Sendable {
    public var phase: String
    public var token: String
    public var extra: String

    public init(phase: String, token: String = "", extra: String = "") {
        self.phase = phase
        self.token = token
        self.extra = extra
    }
}

public struct SyncDeletion: Equatable, Sendable {
    public var remoteID: String?
    public var relativePath: String?

    public init(remoteID: String? = nil, relativePath: String? = nil) {
        self.remoteID = remoteID
        self.relativePath = relativePath
    }
}

public struct SyncPage: Sendable {
    public var upserts: [RemoteItem]
    public var deletions: [SyncDeletion]
    public var cursor: SyncCursor
    public var hasMore: Bool
    /// Pages of a full listing. The mirror is updated on the page that clears this.
    public var deferMirror: Bool
    public var beginsReplacement: Bool
    public var endsReplacement: Bool
    public var accountName: String?
    /// Parent remote id -> child remote ids for folders that were relisted. Children missing from the set are deletions.
    public var refreshedChildren: [String: Set<String>]

    public init(
        upserts: [RemoteItem] = [],
        deletions: [SyncDeletion] = [],
        cursor: SyncCursor,
        hasMore: Bool,
        deferMirror: Bool = false,
        beginsReplacement: Bool = false,
        endsReplacement: Bool = false,
        accountName: String? = nil,
        refreshedChildren: [String: Set<String>] = [:]
    ) {
        self.upserts = upserts
        self.deletions = deletions
        self.cursor = cursor
        self.hasMore = hasMore
        self.deferMirror = deferMirror
        self.beginsReplacement = beginsReplacement
        self.endsReplacement = endsReplacement
        self.accountName = accountName
        self.refreshedChildren = refreshedChildren
    }
}

public enum ProviderError: Error, Equatable, LocalizedError {
    case notConfigured(String)
    case unauthorized
    case http(status: Int, body: String)
    case parse(String)
    case invalidPath
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message): message
        case .unauthorized: "Sign in again. The provider rejected the saved token."
        case .http(let status, let body): "The provider returned HTTP \(status). \(body)"
        case .parse(let message): message
        case .invalidPath: "A remote path could not be stored in the local mirror."
        case .transport(let message): message
        }
    }
}

public enum CloudPath {
    public static func join(_ parent: String, _ name: String) -> String {
        let parent = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if parent.isEmpty { return name }
        if name.isEmpty { return parent }
        return parent + "/" + name
    }

    public static func parent(_ path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[..<index])
    }

    public static func name(_ path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: index)...])
    }
}
