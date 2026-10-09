import os
import XCTest
@testable import ProviderKit

final class MirrorAndSyncTests: XCTestCase {
    func testMirrorSetsLogicalSizeAndMtime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modified = Date(timeIntervalSince1970: 1_704_163_845)
        let items = [
            RemoteItem(remoteID: "dir", name: "Docs", relativePath: "Docs", size: 0, modified: modified, kind: .folder),
            RemoteItem(remoteID: "file", name: "Report.pdf", relativePath: "Docs/Report.pdf", size: 8_000_000, modified: modified, kind: .file),
        ]
        try MetadataMirror.apply(accountRoot: root, items: items)
        let file = root.appendingPathComponent("Docs/Report.pdf")
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .totalFileAllocatedSizeKey])
        XCTAssertEqual(values.fileSize.map(UInt64.init), 8_000_000)
        let seen = try XCTUnwrap(values.contentModificationDate)
        XCTAssertEqual(seen.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 2)
        if let allocated = values.totalFileAllocatedSize {
            XCTAssertLessThan(allocated, 8_000_000)
        }
        let handle = try FileHandle(forReadingFrom: file)
        let prefix = try handle.read(upToCount: 16) ?? Data()
        try handle.close()
        XCTAssertEqual(prefix, Data(repeating: 0, count: prefix.count))

        try MetadataMirror.apply(accountRoot: root, items: [items[0]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Docs").path))
    }

    func testCatalogRoundTripAndStaleGeneration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = try Catalog(databaseURL: url)
        var account = Account(kind: .dropbox, displayName: "Dropbox", config: .dropbox)
        try await catalog.upsertAccount(account)
        let item = RemoteItem(remoteID: "1", name: "a.txt", relativePath: "a.txt", size: 4, modified: Date(timeIntervalSince1970: 10), kind: .file)
        try await catalog.upsertItems(account: account.id, [item], generation: 1)
        account.replaceGeneration = 1
        try await catalog.upsertAccount(account)
        let loaded = try await catalog.items(account: account.id)
        XCTAssertEqual(loaded.map(\.relativePath), ["a.txt"])
        XCTAssertEqual(loaded.first?.size, 4)
        try await catalog.deleteStale(account: account.id, keeping: 2)
        let gone = try await catalog.items(account: account.id)
        XCTAssertTrue(gone.isEmpty)
        let storedAccount = try await catalog.account(account.id)
        let stored = try XCTUnwrap(storedAccount)
        XCTAssertEqual(stored.displayName, "Dropbox")
        XCTAssertEqual(stored.kind, .dropbox)
    }

    func testGoogleSyncWritesMirrorWithoutDownloadingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try Catalog(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        let account = Account(kind: .googleDrive, displayName: "Google Drive", config: .google)
        try await catalog.upsertAccount(account)
        let credentials = MemoryCredentialStore()
        try credentials.save(account.id, .oauth(accessToken: "token", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)))
        let http = ScriptedHTTP(routes: [
            .init(match: { $0.url?.path.contains("startPageToken") == true }, result: HTTPResult(status: 200, data: Data(Fixtures.googleStart.utf8))),
            .init(match: { $0.url?.path.contains("/drive/v3/files") == true }, result: HTTPResult(status: 200, data: Data(Fixtures.googleFiles.utf8))),
        ])
        let refresh = RecordingRefresh()
        let engine = SyncEngine(
            catalog: catalog,
            credentials: credentials,
            http: http,
            refresher: refresh,
            clients: .empty,
            mirrorRoot: directory
        )
        try await engine.sync(accountID: account.id)
        let items = try await catalog.items(account: account.id)
        let file = try XCTUnwrap(items.first { $0.remoteID == "file" })
        XCTAssertEqual(file.relativePath, "Docs/Report.pdf")
        XCTAssertEqual(file.size, 12345)
        let stub = directory.appendingPathComponent(account.id.uuidString).appendingPathComponent("Docs/Report.pdf")
        let values = try stub.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(values.fileSize.map(UInt64.init), 12345)
        let handle = try FileHandle(forReadingFrom: stub)
        let prefix = try handle.read(upToCount: 32) ?? Data()
        try handle.close()
        XCTAssertFalse(prefix.contains(where: { $0 != 0 }))
        XCTAssertEqual(refresh.count, 1)
        let storedAccount = try await catalog.account(account.id)
        let stored = try XCTUnwrap(storedAccount)
        XCTAssertEqual(stored.cursor?.phase, "google.changes")
        XCTAssertEqual(stored.cursor?.token, "99")
        XCTAssertEqual(stored.status, .idle)
        XCTAssertNotNil(stored.lastSync)
    }
}

final class ScriptedHTTP: HTTPSending, @unchecked Sendable {
    struct Route {
        var match: @Sendable (URLRequest) -> Bool
        var result: HTTPResult
    }

    private let routes: OSAllocatedUnfairLock<[Route]>

    init(routes: [Route]) {
        self.routes = OSAllocatedUnfairLock(initialState: routes)
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let result = routes.withLock { routes -> HTTPResult? in
            guard let index = routes.firstIndex(where: { $0.match(request) }) else { return nil }
            return routes.remove(at: index).result
        }
        guard let result else {
            throw ProviderError.transport("unexpected \(request.url?.absoluteString ?? "")")
        }
        return result
    }
}

final class RecordingRefresh: SearchRefreshing, @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }

    func refresh() async throws {
        value.withLock { $0 += 1 }
    }
}
