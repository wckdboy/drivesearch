import Foundation

public struct S3Config: Codable, Sendable, Equatable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var pathStyle: Bool
    public var prefix: String

    public init(endpoint: URL, region: String, bucket: String, pathStyle: Bool, prefix: String = "") {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.pathStyle = pathStyle
        self.prefix = prefix
    }

    public static func preset(named name: String) -> S3Config {
        switch name {
        case "hetzner":
            S3Config(
                endpoint: URL(string: "https://fsn1.your-objectstorage.com")!,
                region: "fsn1",
                bucket: "",
                pathStyle: false
            )
        case "r2":
            S3Config(
                endpoint: URL(string: "https://example.r2.cloudflarestorage.com")!,
                region: "auto",
                bucket: "",
                pathStyle: true
            )
        case "minio":
            S3Config(
                endpoint: URL(string: "https://minio.example.com")!,
                region: "us-east-1",
                bucket: "",
                pathStyle: true
            )
        default:
            S3Config(
                endpoint: URL(string: "https://s3.amazonaws.com")!,
                region: "us-east-1",
                bucket: "",
                pathStyle: false
            )
        }
    }
}

public enum AccountConfig: Codable, Sendable, Equatable {
    case google
    case oneDrive
    case dropbox
    case nextcloud(server: URL, username: String)
    case s3(S3Config)
    case proton(folderName: String, bookmark: Data)
}

public struct Account: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var kind: ProviderKind
    public var displayName: String
    public var config: AccountConfig
    public var status: SyncStatus
    public var lastError: String?
    public var lastSync: Date?
    public var cursor: SyncCursor?
    public var itemCount: Int
    /// Generation stamped onto rows while a full listing is in progress.
    public var replaceGeneration: Int64?

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        displayName: String,
        config: AccountConfig,
        status: SyncStatus = .idle,
        lastError: String? = nil,
        lastSync: Date? = nil,
        cursor: SyncCursor? = nil,
        itemCount: Int = 0,
        replaceGeneration: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.config = config
        self.status = status
        self.lastError = lastError
        self.lastSync = lastSync
        self.cursor = cursor
        self.itemCount = itemCount
        self.replaceGeneration = replaceGeneration
    }
}

public enum SyncStatus: String, Codable, Sendable, Equatable {
    case idle
    case syncing
    case error
    case needsSignIn
}

public enum Credentials: Codable, Sendable, Equatable {
    case oauth(accessToken: String, refreshToken: String?, expiresAt: Date?)
    case basic(username: String, secret: String)
    case s3(accessKeyID: String, secretAccessKey: String)
    case none

    public var oauth: (accessToken: String, refreshToken: String?, expiresAt: Date?)? {
        if case .oauth(let accessToken, let refreshToken, let expiresAt) = self {
            return (accessToken, refreshToken, expiresAt)
        }
        return nil
    }
}

public struct OAuthClientConfig: Sendable, Equatable {
    public var googleClientID: String
    public var googleURLScheme: String
    public var microsoftClientID: String
    public var dropboxAppKey: String

    public init(googleClientID: String, googleURLScheme: String, microsoftClientID: String, dropboxAppKey: String) {
        self.googleClientID = googleClientID
        self.googleURLScheme = googleURLScheme
        self.microsoftClientID = microsoftClientID
        self.dropboxAppKey = dropboxAppKey
    }

    public static let empty = OAuthClientConfig(googleClientID: "", googleURLScheme: "drivesearch-google", microsoftClientID: "", dropboxAppKey: "")

    /// Google's iOS client redirect. One slash after the scheme, as the console registers it.
    public var googleRedirectURI: String {
        "\(googleURLScheme):/oauth2redirect"
    }

    public var appRedirectURI: String { "drivesearch://oauth-callback" }

    public func clientID(for kind: ProviderKind) -> String {
        switch kind {
        case .googleDrive: googleClientID
        case .oneDrive: microsoftClientID
        case .dropbox: dropboxAppKey
        case .nextcloud, .s3, .protonFiles: ""
        }
    }

    public func redirectURI(for kind: ProviderKind) -> String {
        switch kind {
        case .googleDrive: googleRedirectURI
        case .oneDrive, .dropbox: appRedirectURI
        case .nextcloud, .s3, .protonFiles: ""
        }
    }
}
