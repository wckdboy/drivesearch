import Foundation

struct NextcloudEntry: Equatable, Sendable {
    var href: String
    var displayName: String
    var etag: String
    var fileID: String
    var size: UInt64
    var modified: Date
    var isCollection: Bool
    var relativePath: String
}

public enum Nextcloud {
    static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:prop>
        <d:getetag/>
        <d:getcontentlength/>
        <d:getlastmodified/>
        <d:resourcetype/>
        <d:displayname/>
        <oc:fileid/>
      </d:prop>
    </d:propfind>
    """

    public static func rootPrefix(username: String) -> String {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        return "/remote.php/dav/files/\(encoded)/"
    }

    static func filesURL(server: URL, username: String, relative: String = "") -> URL? {
        let base = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = rootPrefix(username: username)
        let suffix = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        return URL(string: base + prefix + suffix)
    }

    static func parseMultistatus(_ data: Data, rootPrefix prefix: String) throws -> [NextcloudEntry] {
        let parser = NextcloudXML(prefix: prefix)
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        guard xml.parse() else {
            throw ProviderError.parse(xml.parserError?.localizedDescription ?? "Could not read the Nextcloud PROPFIND response.")
        }
        return parser.entries
    }

    static func items(from entries: [NextcloudEntry]) -> [RemoteItem] {
        var items: [RemoteItem] = entries.compactMap { entry in
            if entry.relativePath.isEmpty { return nil }
            return RemoteItem(
                remoteID: entry.fileID.isEmpty ? entry.relativePath : entry.fileID,
                parentRemoteID: nil,
                name: entry.displayName.isEmpty ? CloudPath.name(entry.relativePath) : entry.displayName,
                relativePath: entry.relativePath,
                size: entry.isCollection ? 0 : entry.size,
                modified: entry.modified,
                kind: entry.isCollection ? .folder : .file,
                etag: entry.etag
            )
        }
        linkParents(&items)
        return items
    }

    static func linkParents(_ items: inout [RemoteItem]) {
        var folderID: [String: String] = [:]
        for item in items where item.kind == .folder {
            folderID[item.relativePath] = item.remoteID
        }
        for index in items.indices {
            let parent = CloudPath.parent(items[index].relativePath)
            if parent.isEmpty { continue }
            items[index].parentRemoteID = folderID[parent]
        }
    }

    static func etagMap(_ entries: [NextcloudEntry]) -> [String: String] {
        var map: [String: String] = [:]
        for entry in entries where entry.isCollection {
            map[normalize(entry.href)] = entry.etag
        }
        return map
    }

    static func normalize(_ href: String) -> String {
        var path = href
        if let url = URL(string: href), url.host != nil {
            path = url.path
        }
        path = path.removingPercentEncoding ?? path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func relative(href: String, rootPrefix prefix: String) -> String {
        var path = href
        if let url = URL(string: href), url.host != nil {
            path = url.path
        }
        path = path.removingPercentEncoding ?? path
        let root = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        if path == prefix || path == root || path + "/" == prefix {
            return ""
        }
        if path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        } else if path.hasPrefix(root + "/") {
            path = String(path.dropFirst(root.count + 1))
        }
        if path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func browserURL(server: URL, item: RemoteItem) -> URL? {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        components?.path = "/index.php/apps/files/"
        let directory = "/" + CloudPath.parent(item.relativePath)
        components?.queryItems = [
            URLQueryItem(name: "dir", value: directory),
            URLQueryItem(name: "openfile", value: item.remoteID),
        ]
        return components?.url
    }

    public struct LoginChallenge: Equatable, Sendable {
        public var token: String
        public var endpoint: URL
        public var login: URL

        public init(token: String, endpoint: URL, login: URL) {
            self.token = token
            self.endpoint = endpoint
            self.login = login
        }
    }

    public static func loginStartRequest(server: URL) -> URLRequest? {
        let base = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/index.php/login/v2") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func parseLoginStart(_ data: Data) throws -> LoginChallenge {
        let object = try HTTP.json(data)
        guard
            let poll = object["poll"] as? [String: Any],
            let token = poll["token"] as? String,
            let endpoint = (poll["endpoint"] as? String).flatMap(URL.init(string:)),
            let login = (object["login"] as? String).flatMap(URL.init(string:))
        else {
            throw ProviderError.parse("Nextcloud did not return a login-flow challenge.")
        }
        return LoginChallenge(token: token, endpoint: endpoint, login: login)
    }

    public static func loginPollRequest(_ challenge: LoginChallenge) -> URLRequest {
        var request = URLRequest(url: challenge.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.form(["token": challenge.token])
        return request
    }

    /// `nil` while the user has not finished signing in (HTTP 404).
    public static func parseLoginPoll(_ result: HTTPResult) throws -> (server: URL, username: String, appPassword: String)? {
        if result.status == 404 { return nil }
        let data = try HTTP.require(result)
        let object = try HTTP.json(data)
        guard
            let server = (object["server"] as? String).flatMap(URL.init(string:)),
            let username = object["loginName"] as? String,
            let password = object["appPassword"] as? String
        else {
            throw ProviderError.parse("Nextcloud did not return an app password.")
        }
        return (server, username, password)
    }
}

struct NextcloudWalk: Equatable, Sendable {
    var items: [RemoteItem]
    var etags: [String: String]
    /// Parent file id -> child file ids, for folders whose listing was fetched.
    var childrenByParent: [String: Set<String>]
}

enum NextcloudWalker {
    /// Depth-1 walk. A folder whose etag is unchanged is not opened again.
    static func walk(
        rootHref: String,
        previousEtags: [String: String],
        list: (_ href: String) async throws -> [NextcloudEntry]
    ) async throws -> NextcloudWalk {
        var etags = previousEtags
        var items: [RemoteItem] = []
        var children: [String: Set<String>] = [:]

        func recurse(_ href: String) async throws {
            let entries = try await list(href)
            let normalized = Nextcloud.normalize(href)
            let own = entries.first(where: { Nextcloud.normalize($0.href) == normalized })
            if let own { etags[normalized] = own.etag }
            let ownID = own?.fileID ?? ""
            let parentID = ownID.isEmpty ? normalized : ownID
            let childrenEntries = entries.filter { Nextcloud.normalize($0.href) != normalized }
            var childIDs: Set<String> = []
            for entry in childrenEntries {
                let remoteID = entry.fileID.isEmpty ? entry.relativePath : entry.fileID
                childIDs.insert(remoteID)
                if !entry.relativePath.isEmpty {
                    items.append(RemoteItem(
                        remoteID: remoteID,
                        parentRemoteID: parentID,
                        name: entry.displayName.isEmpty ? CloudPath.name(entry.relativePath) : entry.displayName,
                        relativePath: entry.relativePath,
                        size: entry.isCollection ? 0 : entry.size,
                        modified: entry.modified,
                        kind: entry.isCollection ? .folder : .file,
                        etag: entry.etag
                    ))
                }
                if entry.isCollection {
                    let key = Nextcloud.normalize(entry.href)
                    if previousEtags[key] == entry.etag, !entry.etag.isEmpty {
                        etags[key] = entry.etag
                    } else {
                        try await recurse(entry.href)
                    }
                }
            }
            children[parentID] = childIDs
        }

        try await recurse(rootHref)
        return NextcloudWalk(items: items, etags: etags, childrenByParent: children)
    }
}

private final class NextcloudXML: NSObject, XMLParserDelegate {
    let prefix: String
    var entries: [NextcloudEntry] = []
    private var text = ""
    private var href = ""
    private var displayName = ""
    private var etag = ""
    private var fileID = ""
    private var size: UInt64 = 0
    private var modified = Date(timeIntervalSince1970: 0)
    private var isCollection = false
    private var keepProp = true
    private var inResponse = false

    init(prefix: String) {
        self.prefix = prefix
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        let name = elementName
        if name == "response" {
            inResponse = true
            href = ""
            displayName = ""
            etag = ""
            fileID = ""
            size = 0
            modified = Date(timeIntervalSince1970: 0)
            isCollection = false
            keepProp = true
        } else if name == "propstat" {
            keepProp = true
        } else if name == "collection" {
            isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href" where inResponse && href.isEmpty:
            href = value
        case "displayname" where keepProp:
            displayName = value
        case "getetag" where keepProp:
            etag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "fileid" where keepProp:
            fileID = value
        case "getcontentlength" where keepProp:
            size = UInt64(value) ?? 0
        case "getlastmodified" where keepProp:
            modified = ProviderDate.parse(value) ?? modified
        case "status":
            if !value.contains("200") { keepProp = false }
        case "response":
            let relative = Nextcloud.relative(href: href, rootPrefix: prefix)
            entries.append(NextcloudEntry(
                href: href,
                displayName: displayName,
                etag: etag,
                fileID: fileID,
                size: size,
                modified: modified,
                isCollection: isCollection,
                relativePath: relative
            ))
            inResponse = false
        default:
            break
        }
        text = ""
    }
}

struct NextcloudProvider: CloudProvider, Sendable {
    let kind: ProviderKind = .nextcloud

    func authorizationURL(config: OAuthClientConfig, challenge: String, state: String) throws -> URL {
        throw ProviderError.notConfigured("Nextcloud uses the login flow, not an OAuth client id.")
    }

    func exchange(code: String, config: OAuthClientConfig, verifier: String, http: HTTPSending) async throws -> Credentials {
        throw ProviderError.notConfigured("Nextcloud uses the login flow, not an authorization code.")
    }

    func pull(
        account: Account,
        credentials: Credentials,
        config: OAuthClientConfig,
        http: HTTPSending
    ) async throws -> (page: SyncPage, credentials: Credentials) {
        guard case .nextcloud(let server, let username) = account.config else {
            throw ProviderError.parse("This account is not a Nextcloud account.")
        }
        guard case .basic(let user, let secret) = credentials else { throw ProviderError.unauthorized }
        let prefix = Nextcloud.rootPrefix(username: username)
        if account.cursor == nil {
            if let page = try await infinity(server: server, username: user, secret: secret, prefix: prefix, http: http) {
                return (page, credentials)
            }
        }
        let previous = (account.cursor?.extra).flatMap { decodeEtags($0) } ?? [:]
        let walk = try await NextcloudWalker.walk(rootHref: prefix, previousEtags: previous) { href in
            let relative = Nextcloud.relative(href: href, rootPrefix: prefix)
            guard let url = Nextcloud.filesURL(server: server, username: user, relative: relative) else {
                throw ProviderError.parse("Could not build a Nextcloud URL.")
            }
            let data = try await propfind(url: url, depth: "1", user: user, secret: secret, http: http)
            return try Nextcloud.parseMultistatus(data, rootPrefix: prefix)
        }
        let page = SyncPage(
            upserts: walk.items,
            cursor: SyncCursor(phase: "nextcloud.etags", extra: encodeEtags(walk.etags)),
            hasMore: false,
            deferMirror: false,
            beginsReplacement: account.cursor == nil,
            endsReplacement: account.cursor == nil,
            refreshedChildren: walk.childrenByParent
        )
        return (page, credentials)
    }

    func browserURL(item: RemoteItem, account: Account) -> URL? {
        guard case .nextcloud(let server, _) = account.config else { return nil }
        return Nextcloud.browserURL(server: server, item: item)
    }

    func downloadRequest(item: RemoteItem, account: Account, credentials: Credentials) throws -> URLRequest? {
        guard case .nextcloud(let server, let username) = account.config,
              case .basic(let user, let secret) = credentials,
              item.kind == .file,
              let url = Nextcloud.filesURL(server: server, username: username, relative: item.relativePath)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        HTTP.basic(username: user, secret: secret, &request)
        return request
    }

    private func infinity(server: URL, username: String, secret: String, prefix: String, http: HTTPSending) async throws -> SyncPage? {
        guard let url = Nextcloud.filesURL(server: server, username: username) else { return nil }
        do {
            let data = try await propfind(url: url, depth: "infinity", user: username, secret: secret, http: http)
            let entries = try Nextcloud.parseMultistatus(data, rootPrefix: prefix)
            let extra = encodeEtags(Nextcloud.etagMap(entries))
            return SyncPage(
                upserts: Nextcloud.items(from: entries),
                cursor: SyncCursor(phase: "nextcloud.etags", extra: extra),
                hasMore: false,
                deferMirror: false,
                beginsReplacement: true,
                endsReplacement: true
            )
        } catch ProviderError.http {
            return nil
        }
    }

    private func propfind(url: URL, depth: String, user: String, secret: String, http: HTTPSending) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Nextcloud.propfindBody.utf8)
        HTTP.basic(username: user, secret: secret, &request)
        request.timeoutInterval = depth == "infinity" ? 120 : 30
        return try HTTP.require(try await http.send(request), allowing: [207])
    }

    private func encodeEtags(_ etags: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: etags) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeEtags(_ extra: String) -> [String: String]? {
        guard let data = extra.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return object
    }
}
