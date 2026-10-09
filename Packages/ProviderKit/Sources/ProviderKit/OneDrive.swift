import Foundation

enum OneDrive {
    static let scope = "offline_access Files.Read User.Read"

    static func authorizeURL(clientID: String, redirectURI: String, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    static func tokenRequest(code: String, clientID: String, redirectURI: String, verifier: String) -> URLRequest {
        formToken([
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
    }

    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formToken([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "scope": scope,
        ])
    }

    static func parseDelta(_ data: Data) throws -> (upserts: [RemoteItem], deletions: [SyncDeletion], next: String?, delta: String?) {
        let object = try HTTP.json(data)
        var upserts: [RemoteItem] = []
        var deletions: [SyncDeletion] = []
        for value in object["value"] as? [[String: Any]] ?? [] {
            guard let id = value["id"] as? String else { continue }
            if value["deleted"] != nil {
                deletions.append(SyncDeletion(remoteID: id))
                continue
            }
            guard let name = value["name"] as? String else { continue }
            let parent = value["parentReference"] as? [String: Any]
            let parentPath = parent?["path"] as? String
            let relative = relativePath(parentPath: parentPath, name: name)
            let isFolder = value["folder"] != nil
            let size = (value["size"] as? NSNumber)?.uint64Value ?? 0
            let modified = (value["lastModifiedDateTime"] as? String).flatMap(ProviderDate.parse) ?? Date(timeIntervalSince1970: 0)
            let web = (value["webUrl"] as? String).flatMap(URL.init(string:))
            upserts.append(RemoteItem(
                remoteID: id,
                parentRemoteID: parent?["id"] as? String,
                name: name,
                relativePath: relative,
                size: size,
                modified: modified,
                kind: isFolder ? .folder : .file,
                webURL: web
            ))
        }
        return (upserts, deletions, object["@odata.nextLink"] as? String, object["@odata.deltaLink"] as? String)
    }

    static func relativePath(parentPath: String?, name: String) -> String {
        var parent = parentPath ?? ""
        if let marker = parent.range(of: "root:") {
            parent = String(parent[marker.upperBound...])
        }
        parent = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return CloudPath.join(parent, name)
    }

    static func parseToken(_ data: Data, previousRefresh: String?) throws -> Credentials {
        let object = try HTTP.json(data)
        guard let access = object["access_token"] as? String else {
            throw ProviderError.parse("Microsoft did not return an access token.")
        }
        let refresh = object["refresh_token"] as? String ?? previousRefresh
        let expires = (object["expires_in"] as? Int).map { Date().addingTimeInterval(TimeInterval($0 - 60)) }
        return .oauth(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    private static func formToken(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.form(fields)
        return request
    }
}

struct OneDriveProvider: CloudProvider, Sendable {
    let kind: ProviderKind = .oneDrive

    func authorizationURL(config: OAuthClientConfig, challenge: String, state: String) throws -> URL {
        guard !config.microsoftClientID.isEmpty else {
            throw ProviderError.notConfigured("Set MICROSOFT_CLIENT_ID in Config/Secrets.xcconfig.")
        }
        guard let url = OneDrive.authorizeURL(
            clientID: config.microsoftClientID,
            redirectURI: config.appRedirectURI,
            challenge: challenge,
            state: state
        ) else {
            throw ProviderError.notConfigured("Could not build the Microsoft sign-in URL.")
        }
        return url
    }

    func exchange(code: String, config: OAuthClientConfig, verifier: String, http: HTTPSending) async throws -> Credentials {
        let request = OneDrive.tokenRequest(
            code: code,
            clientID: config.microsoftClientID,
            redirectURI: config.appRedirectURI,
            verifier: verifier
        )
        return try OneDrive.parseToken(try HTTP.require(try await http.send(request)), previousRefresh: nil)
    }

    func pull(
        account: Account,
        credentials: Credentials,
        config: OAuthClientConfig,
        http: HTTPSending
    ) async throws -> (page: SyncPage, credentials: Credentials) {
        var credentials = try await refreshed(credentials, config: config, http: http)
        guard let token = credentials.oauth?.accessToken else { throw ProviderError.unauthorized }
        let replacing = account.cursor == nil || account.cursor?.extra == "replace"
        let url: URL
        if account.cursor?.phase == "onedrive.page", let link = account.cursor?.token, let saved = URL(string: link) {
            url = saved
        } else if account.cursor?.phase == "onedrive.delta", let link = account.cursor?.token, let saved = URL(string: link) {
            url = saved
        } else {
            var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/drive/root/delta")!
            components.queryItems = [
                URLQueryItem(name: "$select", value: "id,name,size,lastModifiedDateTime,parentReference,file,folder,deleted,webUrl"),
            ]
            url = components.url!
        }
        var request = URLRequest(url: url)
        HTTP.bearer(token, &request)
        let parsed = try OneDrive.parseDelta(try HTTP.require(try await http.send(request)))
        let hasMore = parsed.next != nil
        let cursor = SyncCursor(
            phase: hasMore ? "onedrive.page" : "onedrive.delta",
            token: parsed.next ?? parsed.delta ?? "",
            extra: replacing ? "replace" : ""
        )
        let page = SyncPage(
            upserts: parsed.upserts,
            deletions: parsed.deletions,
            cursor: cursor,
            hasMore: hasMore,
            deferMirror: hasMore && replacing,
            beginsReplacement: account.cursor == nil,
            endsReplacement: !hasMore && replacing
        )
        return (page, credentials)
    }

    func browserURL(item: RemoteItem, account: Account) -> URL? {
        item.webURL
    }

    func downloadRequest(item: RemoteItem, account: Account, credentials: Credentials) throws -> URLRequest? {
        guard let token = credentials.oauth?.accessToken else { return nil }
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(item.remoteID)/content") else { return nil }
        var request = URLRequest(url: url)
        HTTP.bearer(token, &request)
        return request
    }

    private func refreshed(_ credentials: Credentials, config: OAuthClientConfig, http: HTTPSending) async throws -> Credentials {
        guard let oauth = credentials.oauth else { throw ProviderError.unauthorized }
        if let expiry = oauth.expiresAt, expiry > Date() { return credentials }
        guard let refresh = oauth.refreshToken else { return credentials }
        let result = try await http.send(OneDrive.refreshRequest(refreshToken: refresh, clientID: config.microsoftClientID))
        return try OneDrive.parseToken(try HTTP.require(result), previousRefresh: refresh)
    }
}
