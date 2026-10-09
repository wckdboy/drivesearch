import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func load(_ account: UUID) throws -> Credentials?
    func save(_ account: UUID, _ credentials: Credentials) throws
    func delete(_ account: UUID) throws
}

public final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Credentials] = [:]

    public init() {}

    public func load(_ account: UUID) throws -> Credentials? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    public func save(_ account: UUID, _ credentials: Credentials) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = credentials
    }

    public func delete(_ account: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = nil
    }
}

public final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "dev.wckdboy.drivesearch.credentials") {
        self.service = service
    }

    public func load(_ account: UUID) throws -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderError.transport("Keychain read failed (\(status)).")
        }
        return try JSONDecoder.drive.decode(Credentials.self, from: data)
    }

    public func save(_ account: UUID, _ credentials: Credentials) throws {
        let data = try JSONEncoder.drive.encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else {
                throw ProviderError.transport("Keychain save failed (\(add)).")
            }
            return
        }
        guard status == errSecSuccess else {
            throw ProviderError.transport("Keychain update failed (\(status)).")
        }
    }

    public func delete(_ account: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderError.transport("Keychain delete failed (\(status)).")
        }
    }
}

extension JSONEncoder {
    static var drive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var drive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
