import CryptoKit
import Foundation
import Security

public struct HTTPResult: Sendable, Equatable {
    public var status: Int
    public var data: Data
    public var headers: [String: String]

    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        var lowered: [String: String] = [:]
        for (key, value) in headers {
            lowered[key.lowercased()] = value
        }
        self.headers = lowered
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol HTTPSending: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

public struct URLSessionHTTP: HTTPSending {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("The provider did not return an HTTP response.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                headers[name] = text
            }
        }
        return HTTPResult(status: http.statusCode, data: data, headers: headers)
    }
}

public enum HTTP {
    static let userAgent = "DriveSearch/0.1"

    static func json(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ProviderError.parse("Expected a JSON object.")
        }
        return dictionary
    }

    public static func require(_ result: HTTPResult, allowing: Set<Int> = []) throws -> Data {
        if result.status == 401 || result.status == 403 {
            throw ProviderError.unauthorized
        }
        if (200..<300).contains(result.status) || allowing.contains(result.status) {
            return result.data
        }
        let body = String(data: result.data.prefix(400), encoding: .utf8) ?? ""
        throw ProviderError.http(status: result.status, body: body)
    }

    static func form(_ fields: [String: String]) -> Data {
        let encoded = fields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }.sorted().joined(separator: "&")
        return Data(encoded.utf8)
    }

    static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func bearer(_ token: String, _ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    static func basic(username: String, secret: String, _ request: inout URLRequest) {
        let raw = Data("\(username):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(raw)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
}

public enum ProviderDate {
    public static func parse(_ string: String) -> Date? {
        if let date = iso(string) { return date }
        return rfc1123(string)
    }

    public static func iso(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    public static func rfc1123(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}

public enum PKCEPair: Sendable, Equatable {
    public static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier: String
        if status == errSecSuccess {
            verifier = Data(bytes).base64URLEncoded()
        } else {
            verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return (verifier, challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
