import Foundation

enum Dropbox {
    static let scope = "files.metadata.read files.content.read account_info.read"

    static func authorizeURL(appKey: String, redirectURI: String, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    static func tokenRequest(code: String, appKey: String, redirectURI: String, verifier: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.form([
            "code": code,
            "grant_type": "authorization_code",
            "client_id": appKey,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        return request
    }

    static func refreshRequest(refreshToken: String, appKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.form([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": appKey,
        ])
        return request
    }

    static func parseList(_ data: Data) throws -> (upserts: [RemoteItem], deletions: [SyncDeletion], cursor: String, hasMore: Bool) {
        let object = try HTTP.json(data)
        var upserts: [RemoteItem] = []
        var deletions: [SyncDeletion] = []
        for entry in object["entries"] as? [[String: Any]] ?? [] {
            let tag = entry[".tag"] as? String ?? ""
            let name = entry["name"] as? String ?? CloudPath.name(entry["path_display"] as? String ?? "")
            let display = (entry["path_display"] as? String) ?? (entry["path_lower"] as? String) ?? name
            let relative = display.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let id = entry["id"] as? String
            if tag == "deleted" {
                deletions.append(SyncDeletion(remoteID: id, relativePath: relative))
                continue
            }
            let size = (entry["size"] as? NSNumber)?.uint64Value ?? 0
            let modified = (entry["server_modified"] as? String).flatMap(ProviderDate.parse) ?? Date(timeIntervalSince1970: 0)
            upserts.append(RemoteItem(
                remoteID: id ?? relative,
                name: name.isEmpty ? CloudPath.name(relative) : name,
                relativePath: relative,
                size: size,
                modified: modified,
                kind: tag == "folder" ? .folder : .file
            ))
        }
        guard let cursor = object["cursor"] as? String else {
            throw ProviderError.parse("Dropbox did not return a cursor.")
        }
        return (upserts, deletions, cursor, object["has_more"] as? Bool ?? false)
    }

    static func parseToken(_ data: Data, previousRefresh: String?) throws -> Credentials {
        let object = try HTTP.json(data)
        guard let access = object["access_token"] as? String else {
            throw ProviderError.parse("Dropbox did not return an access token.")
        }
        let refresh = object["refresh_token"] as? String ?? previousRefresh
        let expires = (object["expires_in"] as? Int).map { Date().addingTimeInterval(TimeInterval($0 - 60)) }
        return .oauth(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }
}

struct DropboxProvider: CloudProvider, Sendable {
    let kind: ProviderKind = .dropbox

    func authorizationURL(config: OAuthClientConfig, challenge: String, state: String) throws -> URL {
        guard !config.dropboxAppKey.isEmpty else {
            throw ProviderError.notConfigured("Set DROPBOX_APP_KEY in Config/Secrets.xcconfig.")
        }
        guard let url = Dropbox.authorizeURL(
            appKey: config.dropboxAppKey,
            redirectURI: config.appRedirectURI,
            challenge: challenge,
            state: state
        ) else {
            throw ProviderError.notConfigured("Could not build the Dropbox sign-in URL.")
        }
        return url
    }

    func exchange(code: String, config: OAuthClientConfig, verifier: String, http: HTTPSending) async throws -> Credentials {
        let request = Dropbox.tokenRequest(
            code: code,
            appKey: config.dropboxAppKey,
            redirectURI: config.appRedirectURI,
            verifier: verifier
        )
        return try Dropbox.parseToken(try HTTP.require(try await http.send(request)), previousRefresh: nil)
    }

    func pull(
        account: Account,
        credentials: Credentials,
        config: OAuthClientConfig,
        http: HTTPSending
    ) async throws -> (page: SyncPage, credentials: Credentials) {
        let credentials = try await refreshed(credentials, config: config, http: http)
        guard let token = credentials.oauth?.accessToken else { throw ProviderError.unauthorized }
        let continuing = account.cursor?.phase == "dropbox.page" || account.cursor?.phase == "dropbox.cursor"
        let full = account.cursor == nil || account.cursor?.extra == "full"
        var request: URLRequest
        if continuing {
            request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": account.cursor?.token ?? ""])
        } else {
            request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "path": "",
                "recursive": true,
                "include_deleted": true,
                "limit": 2000,
            ])
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        HTTP.bearer(token, &request)
        let parsed = try Dropbox.parseList(try HTTP.require(try await http.send(request)))
        let page = SyncPage(
            upserts: parsed.upserts,
            deletions: parsed.deletions,
            cursor: SyncCursor(
                phase: parsed.hasMore ? "dropbox.page" : "dropbox.cursor",
                token: parsed.cursor,
                extra: full ? "full" : ""
            ),
            hasMore: parsed.hasMore,
            deferMirror: parsed.hasMore && full,
            beginsReplacement: account.cursor == nil,
            endsReplacement: full && !parsed.hasMore
        )
        return (page, credentials)
    }

    func browserURL(item: RemoteItem, account: Account) -> URL? {
        var components = URLComponents(string: "https://www.dropbox.com/home")
        let path = item.relativePath.hasPrefix("/") ? item.relativePath : "/" + item.relativePath
        components?.path = "/home" + path
        return components?.url
    }

    func downloadRequest(item: RemoteItem, account: Account, credentials: Credentials) throws -> URLRequest? {
        guard item.kind == .file, let token = credentials.oauth?.accessToken else { return nil }
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        HTTP.bearer(token, &request)
        let arg = try JSONSerialization.data(withJSONObject: ["path": item.remoteID.hasPrefix("id:") ? item.remoteID : "/" + item.relativePath])
        request.setValue(String(decoding: arg, as: UTF8.self), forHTTPHeaderField: "Dropbox-API-Arg")
        return request
    }

    private func refreshed(_ credentials: Credentials, config: OAuthClientConfig, http: HTTPSending) async throws -> Credentials {
        guard let oauth = credentials.oauth else { throw ProviderError.unauthorized }
        if let expiry = oauth.expiresAt, expiry > Date() { return credentials }
        guard let refresh = oauth.refreshToken else { return credentials }
        let result = try await http.send(Dropbox.refreshRequest(refreshToken: refresh, appKey: config.dropboxAppKey))
        return try Dropbox.parseToken(try HTTP.require(result), previousRefresh: refresh)
    }
}
