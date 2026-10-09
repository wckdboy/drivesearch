import Foundation

enum GoogleDrive {
    static let folderMIME = "application/vnd.google-apps.folder"
    static let scope = "https://www.googleapis.com/auth/drive.metadata.readonly"

    static func authorizeURL(clientID: String, redirectURI: String, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    static func tokenRequest(code: String, clientID: String, redirectURI: String, verifier: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.form([
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        return request
    }

    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.form([
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token",
        ])
        return request
    }

    static func parseToken(_ data: Data, previousRefresh: String?) throws -> Credentials {
        let object = try HTTP.json(data)
        guard let access = object["access_token"] as? String else {
            throw ProviderError.parse("Google did not return an access token.")
        }
        let refresh = object["refresh_token"] as? String ?? previousRefresh
        let expires = (object["expires_in"] as? Int).map { Date().addingTimeInterval(TimeInterval($0 - 60)) }
        return .oauth(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    static func parseFileList(_ data: Data) throws -> (items: [RemoteItem], nextPage: String?) {
        let object = try HTTP.json(data)
        let files = object["files"] as? [[String: Any]] ?? []
        return (files.compactMap(file), object["nextPageToken"] as? String)
    }

    static func parseChanges(_ data: Data) throws -> (upserts: [RemoteItem], deletions: [SyncDeletion], nextPage: String?, newStart: String?) {
        let object = try HTTP.json(data)
        var upserts: [RemoteItem] = []
        var deletions: [SyncDeletion] = []
        for change in object["changes"] as? [[String: Any]] ?? [] {
            let fileID = change["fileId"] as? String
            let removed = change["removed"] as? Bool ?? false
            if removed {
                deletions.append(SyncDeletion(remoteID: fileID))
                continue
            }
            guard let file = change["file"] as? [String: Any], let item = self.file(file) else {
                deletions.append(SyncDeletion(remoteID: fileID))
                continue
            }
            if (file["trashed"] as? Bool) == true {
                deletions.append(SyncDeletion(remoteID: item.remoteID))
            } else {
                upserts.append(item)
            }
        }
        return (upserts, deletions, object["nextPageToken"] as? String, object["newStartPageToken"] as? String)
    }

    static func parseStartToken(_ data: Data) throws -> String {
        let object = try HTTP.json(data)
        guard let token = object["startPageToken"] as? String else {
            throw ProviderError.parse("Google did not return a changes token.")
        }
        return token
    }

    static func parseAboutName(_ data: Data) throws -> String? {
        let object = try HTTP.json(data)
        let user = object["user"] as? [String: Any]
        return (user?["emailAddress"] as? String) ?? (user?["displayName"] as? String)
    }

    /// Build paths from Drive parent ids. `root` is the drive root. The first parent wins.
    static func resolvePaths(_ items: inout [RemoteItem]) {
        var byID: [String: RemoteItem] = [:]
        for item in items {
            byID[item.remoteID] = item
        }
        func path(for id: String, stack: Set<String>) -> String {
            if stack.contains(id) { return byID[id]?.name ?? "" }
            guard let item = byID[id] else { return "" }
            guard let parent = item.parentRemoteID, parent != "root", !parent.isEmpty else {
                return item.name
            }
            let above = path(for: parent, stack: stack.union([id]))
            if above.isEmpty { return item.name }
            return CloudPath.join(above, item.name)
        }
        for index in items.indices {
            items[index].relativePath = path(for: items[index].remoteID, stack: [])
            items[index].mirrorPath = items[index].relativePath
        }
    }

    static func browserURL(remoteID: String, kind: ItemKind) -> URL? {
        switch kind {
        case .folder:
            URL(string: "https://drive.google.com/drive/folders/\(remoteID)")
        case .file:
            URL(string: "https://drive.google.com/file/d/\(remoteID)/view")
        }
    }

    private static func file(_ file: [String: Any]) -> RemoteItem? {
        guard let id = file["id"] as? String, let name = file["name"] as? String else { return nil }
        if (file["trashed"] as? Bool) == true { return nil }
        let mime = file["mimeType"] as? String ?? ""
        let parents = file["parents"] as? [String]
        let size = UInt64(file["size"] as? String ?? "") ?? 0
        let modified = (file["modifiedTime"] as? String).flatMap(ProviderDate.parse) ?? Date(timeIntervalSince1970: 0)
        let web = (file["webViewLink"] as? String).flatMap(URL.init(string:))
        return RemoteItem(
            remoteID: id,
            parentRemoteID: parents?.first,
            name: name,
            relativePath: name,
            size: size,
            modified: modified,
            kind: mime == folderMIME ? .folder : .file,
            webURL: web
        )
    }
}

struct GoogleDriveProvider: CloudProvider, Sendable {
    let kind: ProviderKind = .googleDrive

    func authorizationURL(config: OAuthClientConfig, challenge: String, state: String) throws -> URL {
        guard !config.googleClientID.isEmpty else {
            throw ProviderError.notConfigured("Set GOOGLE_CLIENT_ID in Config/Secrets.xcconfig.")
        }
        guard let url = GoogleDrive.authorizeURL(
            clientID: config.googleClientID,
            redirectURI: config.googleRedirectURI,
            challenge: challenge,
            state: state
        ) else {
            throw ProviderError.notConfigured("Could not build the Google sign-in URL.")
        }
        return url
    }

    func exchange(code: String, config: OAuthClientConfig, verifier: String, http: HTTPSending) async throws -> Credentials {
        let request = GoogleDrive.tokenRequest(
            code: code,
            clientID: config.googleClientID,
            redirectURI: config.googleRedirectURI,
            verifier: verifier
        )
        let result = try await http.send(request)
        return try GoogleDrive.parseToken(try HTTP.require(result), previousRefresh: nil)
    }

    func pull(
        account: Account,
        credentials: Credentials,
        config: OAuthClientConfig,
        http: HTTPSending
    ) async throws -> (page: SyncPage, credentials: Credentials) {
        var credentials = credentials
        credentials = try await refreshed(credentials, config: config, http: http)
        guard let token = credentials.oauth?.accessToken else { throw ProviderError.unauthorized }
        let cursor = account.cursor
        if cursor == nil || cursor?.phase == "google.start" {
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/changes/startPageToken")!)
            HTTP.bearer(token, &request)
            let start = try GoogleDrive.parseStartToken(try HTTP.require(try await http.send(request)))
            let page = try await listPage(token: token, pageToken: nil, startToken: start, http: http, first: true)
            return (page, credentials)
        }
        if cursor?.phase == "google.list" {
            let page = try await listPage(token: token, pageToken: cursor?.token, startToken: cursor?.extra ?? "", http: http, first: false)
            return (page, credentials)
        }
        let pageToken = cursor?.token ?? ""
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/changes")!
        components.queryItems = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "includeRemoved", value: "true"),
            URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,size,modifiedTime,parents,trashed,webViewLink))"),
        ]
        var request = URLRequest(url: components.url!)
        HTTP.bearer(token, &request)
        let parsed = try GoogleDrive.parseChanges(try HTTP.require(try await http.send(request)))
        let hasMore = parsed.nextPage != nil
        let next = SyncCursor(
            phase: "google.changes",
            token: parsed.nextPage ?? parsed.newStart ?? pageToken,
            extra: ""
        )
        let page = SyncPage(
            upserts: parsed.upserts,
            deletions: parsed.deletions,
            cursor: next,
            hasMore: hasMore,
            deferMirror: false,
            beginsReplacement: false,
            endsReplacement: false
        )
        return (page, credentials)
    }

    func browserURL(item: RemoteItem, account: Account) -> URL? {
        item.webURL ?? GoogleDrive.browserURL(remoteID: item.remoteID, kind: item.kind)
    }

    func downloadRequest(item: RemoteItem, account: Account, credentials: Credentials) throws -> URLRequest? {
        nil
    }

    private func listPage(token: String, pageToken: String?, startToken: String, http: HTTPSending, first: Bool) async throws -> SyncPage {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        var items = [
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "q", value: "trashed=false"),
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,parents,trashed,webViewLink)"),
        ]
        if let pageToken, !pageToken.isEmpty {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        HTTP.bearer(token, &request)
        let parsed = try GoogleDrive.parseFileList(try HTTP.require(try await http.send(request)))
        let hasMore = parsed.nextPage != nil
        let cursor = SyncCursor(
            phase: hasMore ? "google.list" : "google.changes",
            token: parsed.nextPage ?? startToken,
            extra: startToken
        )
        return SyncPage(
            upserts: parsed.items,
            cursor: cursor,
            hasMore: hasMore,
            deferMirror: hasMore,
            beginsReplacement: first,
            endsReplacement: !hasMore
        )
    }

    private func refreshed(_ credentials: Credentials, config: OAuthClientConfig, http: HTTPSending) async throws -> Credentials {
        guard let oauth = credentials.oauth else { throw ProviderError.unauthorized }
        if let expiry = oauth.expiresAt, expiry > Date() { return credentials }
        guard let refresh = oauth.refreshToken else { return credentials }
        let result = try await http.send(GoogleDrive.refreshRequest(refreshToken: refresh, clientID: config.googleClientID))
        if result.status == 401 { throw ProviderError.unauthorized }
        return try GoogleDrive.parseToken(try HTTP.require(result), previousRefresh: refresh)
    }
}
