import CryptoKit
import Foundation

enum SigV4 {
    struct Signed: Equatable {
        var canonicalRequest: String
        var stringToSign: String
        var signature: String
        var authorization: String
    }

    static func sign(
        method: String,
        url: URL,
        region: String,
        service: String = "s3",
        headers: [String: String],
        payloadHash: String,
        accessKeyID: String,
        secretAccessKey: String,
        amzDate: String
    ) -> Signed {
        let dateStamp = String(amzDate.prefix(8))
        let canonicalURI = canonicalURI(url.path)
        let canonicalQuery = canonicalQuery(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        var signedHeaders = headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
        signedHeaders.append(("x-amz-date", amzDate))
        signedHeaders.append(("x-amz-content-sha256", payloadHash))
        var merged: [String: String] = [:]
        for (key, value) in signedHeaders {
            merged[key] = value
        }
        let names = merged.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(merged[$0]!)\n" }.joined()
        let signed = names.joined(separator: ";")
        let canonical = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signed,
            payloadHash,
        ].joined(separator: "\n")
        let hash = sha256(Data(canonical.utf8))
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hash].joined(separator: "\n")
        let signature = hmacHex(key: signingKey(secret: secretAccessKey, date: dateStamp, region: region, service: service), message: stringToSign)
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signed), Signature=\(signature)"
        return Signed(canonicalRequest: canonical, stringToSign: stringToSign, signature: signature, authorization: authorization)
    }

    static func emptyPayloadHash() -> String {
        sha256(Data())
    }

    static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func canonicalURI(_ path: String) -> String {
        let raw = path.isEmpty ? "/" : path
        return raw.split(separator: "/", omittingEmptySubsequences: false).enumerated().map { index, part in
            if index == 0 && part.isEmpty { return "" }
            return uriEncode(String(part), encodeSlash: true)
        }.joined(separator: "/")
    }

    static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        var pairs: [(name: String, value: String)] = []
        pairs.reserveCapacity(items.count)
        for item in items {
            let name = uriEncode(item.name, encodeSlash: true)
            let value = uriEncode(item.value ?? "", encodeSlash: true)
            pairs.append((name, value))
        }
        pairs.sort { left, right in
            if left.name == right.name {
                return left.value < right.value
            }
            return left.name < right.name
        }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    static func uriEncode(_ value: String, encodeSlash: Bool) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        if !encodeSlash { allowed.insert(charactersIn: "/") }
        var out = ""
        for byte in value.utf8 {
            let scalar = UnicodeScalar(byte)
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hmacHex(key: Data, message: String) -> String {
        hmac(key, message).map { String(format: "%02x", $0) }.joined()
    }

    private static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let kDate = hmac(Data("AWS4\(secret)".utf8), date)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }
}

struct S3Object: Equatable, Sendable {
    var key: String
    var size: UInt64
    var modified: Date
    var etag: String
}

enum S3Listing {
    static func parse(_ data: Data) throws -> (objects: [S3Object], next: String?, truncated: Bool) {
        let parser = S3XML()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        guard xml.parse() else {
            throw ProviderError.parse(xml.parserError?.localizedDescription ?? "Could not read ListObjectsV2.")
        }
        return (parser.objects, parser.next, parser.truncated)
    }

    static func items(objects: [S3Object], prefix: String) -> [RemoteItem] {
        var files: [RemoteItem] = []
        var folders: Set<String> = []
        for object in objects {
            var key = object.key
            if !prefix.isEmpty {
                guard key.hasPrefix(prefix) else { continue }
                key.removeFirst(prefix.count)
                if key.hasPrefix("/") { key.removeFirst() }
            }
            if key.isEmpty { continue }
            if key.hasSuffix("/"), object.size == 0 {
                let folder = String(key.dropLast())
                if !folder.isEmpty { folders.insert(folder) }
                continue
            }
            var parent = CloudPath.parent(key)
            while !parent.isEmpty {
                folders.insert(parent)
                parent = CloudPath.parent(parent)
            }
            files.append(RemoteItem(
                remoteID: object.key,
                name: CloudPath.name(key),
                relativePath: key,
                size: object.size,
                modified: object.modified,
                kind: .file,
                etag: object.etag
            ))
        }
        for folder in folders {
            files.append(RemoteItem(
                remoteID: "folder:" + folder,
                name: CloudPath.name(folder),
                relativePath: folder,
                size: 0,
                modified: files.filter { CloudPath.parent($0.relativePath) == folder }.map(\.modified).max() ?? Date(timeIntervalSince1970: 0),
                kind: .folder
            ))
        }
        return files
    }
}

private final class S3XML: NSObject, XMLParserDelegate {
    var objects: [S3Object] = []
    var next: String?
    var truncated = false
    private var text = ""
    private var inContents = false
    private var key = ""
    private var size: UInt64 = 0
    private var modified = Date(timeIntervalSince1970: 0)
    private var etag = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "Contents" {
            inContents = true
            key = ""
            size = 0
            modified = Date(timeIntervalSince1970: 0)
            etag = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inContents {
            switch elementName {
            case "Key": key = value
            case "Size": size = UInt64(value) ?? 0
            case "LastModified": modified = ProviderDate.parse(value) ?? modified
            case "ETag": etag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "Contents":
                objects.append(S3Object(key: key, size: size, modified: modified, etag: etag))
                inContents = false
            default: break
            }
        } else if elementName == "NextContinuationToken" {
            next = value
        } else if elementName == "IsTruncated" {
            truncated = value == "true"
        }
        text = ""
    }
}

struct S3Provider: CloudProvider, Sendable {
    let kind: ProviderKind = .s3

    func authorizationURL(config: OAuthClientConfig, challenge: String, state: String) throws -> URL {
        throw ProviderError.notConfigured("S3 uses an access key, not OAuth.")
    }

    func exchange(code: String, config: OAuthClientConfig, verifier: String, http: HTTPSending) async throws -> Credentials {
        throw ProviderError.notConfigured("S3 uses an access key, not OAuth.")
    }

    func pull(
        account: Account,
        credentials: Credentials,
        config: OAuthClientConfig,
        http: HTTPSending
    ) async throws -> (page: SyncPage, credentials: Credentials) {
        guard case .s3(let s3) = account.config else { throw ProviderError.parse("This account is not S3.") }
        guard case .s3(let accessKey, let secret) = credentials else { throw ProviderError.unauthorized }
        let continuing = account.cursor?.phase == "s3.page"
        let token = continuing ? account.cursor?.token ?? "" : ""
        let request = try listRequest(s3, accessKey: accessKey, secret: secret, continuation: token, now: Date())
        let parsed = try S3Listing.parse(try HTTP.require(try await http.send(request)))
        let hasMore = parsed.truncated && parsed.next != nil
        let page = SyncPage(
            upserts: S3Listing.items(objects: parsed.objects, prefix: s3.prefix),
            cursor: SyncCursor(phase: hasMore ? "s3.page" : "s3.done", token: parsed.next ?? ""),
            hasMore: hasMore,
            deferMirror: hasMore,
            beginsReplacement: !continuing,
            endsReplacement: !hasMore
        )
        return (page, credentials)
    }

    func browserURL(item: RemoteItem, account: Account) -> URL? {
        nil
    }

    func downloadRequest(item: RemoteItem, account: Account, credentials: Credentials) throws -> URLRequest? {
        guard case .s3(let s3) = account.config, case .s3(let accessKey, let secret) = credentials, item.kind == .file else { return nil }
        return try objectRequest(s3, key: item.remoteID, accessKey: accessKey, secret: secret, now: Date())
    }

    func listRequest(_ config: S3Config, accessKey: String, secret: String, continuation: String, now: Date) throws -> URLRequest {
        var items = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: "1000"),
        ]
        if !config.prefix.isEmpty { items.append(URLQueryItem(name: "prefix", value: config.prefix)) }
        if !continuation.isEmpty { items.append(URLQueryItem(name: "continuation-token", value: continuation)) }
        guard let url = endpointURL(config, key: nil, query: items) else {
            throw ProviderError.parse("The S3 endpoint is not a URL.")
        }
        return sign(method: "GET", url: url, config: config, accessKey: accessKey, secret: secret, payload: Data(), now: now)
    }

    func objectRequest(_ config: S3Config, key: String, accessKey: String, secret: String, now: Date) throws -> URLRequest {
        guard let url = endpointURL(config, key: key, query: []) else {
            throw ProviderError.parse("The S3 endpoint is not a URL.")
        }
        return sign(method: "GET", url: url, config: config, accessKey: accessKey, secret: secret, payload: Data(), now: now)
    }

    private func sign(method: String, url: URL, config: S3Config, accessKey: String, secret: String, payload: Data, now: Date) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let host = url.host ?? ""
        let hash = SigV4.emptyPayloadHash()
        let amz = SigV4.amzDate(now)
        let signed = SigV4.sign(
            method: method,
            url: url,
            region: config.region,
            headers: ["host": host],
            payloadHash: hash,
            accessKeyID: accessKey,
            secretAccessKey: secret,
            amzDate: amz
        )
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amz, forHTTPHeaderField: "x-amz-date")
        request.setValue(hash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func endpointURL(_ config: S3Config, key: String?, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false) else { return nil }
        let host = components.host ?? ""
        if config.pathStyle {
            var path = "/" + config.bucket
            if let key, !key.isEmpty {
                path += "/" + key.split(separator: "/").map { SigV4.uriEncode(String($0), encodeSlash: true) }.joined(separator: "/")
            }
            components.percentEncodedPath = path
        } else {
            components.host = "\(config.bucket).\(host)"
            if let key, !key.isEmpty {
                components.percentEncodedPath = "/" + key.split(separator: "/").map { SigV4.uriEncode(String($0), encodeSlash: true) }.joined(separator: "/")
            } else {
                components.path = "/"
            }
        }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
}
