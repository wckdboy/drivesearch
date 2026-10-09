import XCTest
@testable import ProviderKit

final class ParserTests: XCTestCase {
    func testGoogleFileListResolvesPaths() throws {
        let parsed = try GoogleDrive.parseFileList(Data(Fixtures.googleFiles.utf8))
        var items = parsed.items
        XCTAssertNil(parsed.nextPage)
        GoogleDrive.resolvePaths(&items)
        let file = try XCTUnwrap(items.first { $0.remoteID == "file" })
        XCTAssertEqual(file.relativePath, "Docs/Report.pdf")
        XCTAssertEqual(file.size, 12345)
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.parentRemoteID, "folder")
        let folder = try XCTUnwrap(items.first { $0.remoteID == "folder" })
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.relativePath, "Docs")
    }

    func testGoogleChangesParseRemovedAndTrashed() throws {
        let parsed = try GoogleDrive.parseChanges(Data(Fixtures.googleChanges.utf8))
        XCTAssertEqual(parsed.upserts.map(\.remoteID), ["kept"])
        XCTAssertEqual(Set(parsed.deletions.compactMap(\.remoteID)), ["gone", "trashed"])
        XCTAssertEqual(parsed.newStart, "200")
        XCTAssertNil(parsed.nextPage)
    }

    func testOneDriveDeltaPathsAndDeletes() throws {
        let parsed = try OneDrive.parseDelta(Data(Fixtures.oneDriveDelta.utf8))
        let notes = try XCTUnwrap(parsed.upserts.first { $0.remoteID == "f1" })
        XCTAssertEqual(notes.relativePath, "Documents/Notes.txt")
        XCTAssertEqual(notes.size, 42)
        XCTAssertEqual(notes.kind, .file)
        XCTAssertEqual(notes.webURL?.host, "example.test")
        let folder = try XCTUnwrap(parsed.upserts.first { $0.remoteID == "d1" })
        XCTAssertEqual(folder.relativePath, "Documents")
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(parsed.deletions.map(\.remoteID), ["gone"])
        XCTAssertEqual(parsed.delta, "https://graph.microsoft.com/v1.0/me/drive/root/delta?token=abc")
    }

    func testDropboxListFolder() throws {
        let parsed = try Dropbox.parseList(Data(Fixtures.dropboxList.utf8))
        XCTAssertFalse(parsed.hasMore)
        XCTAssertEqual(parsed.cursor, "cursor-1")
        let file = try XCTUnwrap(parsed.upserts.first { $0.kind == .file })
        XCTAssertEqual(file.relativePath, "Docs/notes.txt")
        XCTAssertEqual(file.size, 100)
        XCTAssertEqual(file.remoteID, "id:file")
        XCTAssertEqual(parsed.deletions.first?.relativePath, "Docs/gone.txt")
        XCTAssertTrue(parsed.upserts.contains { $0.kind == .folder && $0.relativePath == "Docs" })
    }

    func testNextcloudPropfind() throws {
        let entries = try Nextcloud.parseMultistatus(Data(Fixtures.nextcloudPropfind.utf8), rootPrefix: "/remote.php/dav/files/alice/")
        let items = Nextcloud.items(from: entries)
        let report = try XCTUnwrap(items.first { $0.name == "Report.pdf" })
        XCTAssertEqual(report.relativePath, "Documents/Report.pdf")
        XCTAssertEqual(report.size, 100)
        XCTAssertEqual(report.remoteID, "42")
        XCTAssertEqual(report.kind, .file)
        XCTAssertEqual(report.parentRemoteID, "7")
        let folder = try XCTUnwrap(items.first { $0.remoteID == "7" })
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.relativePath, "Documents")
        XCTAssertFalse(items.contains { $0.relativePath.isEmpty })
    }

    func testNextcloudEtagWalkSkipsUnchangedFolders() async throws {
        let root = "/remote.php/dav/files/alice/"
        let docs = NextcloudEntry(
            href: "/remote.php/dav/files/alice/Documents/",
            displayName: "Documents",
            etag: "same",
            fileID: "7",
            size: 0,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            isCollection: true,
            relativePath: "Documents"
        )
        let rootEntry = NextcloudEntry(
            href: root,
            displayName: "alice",
            etag: "root",
            fileID: "1",
            size: 0,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            isCollection: true,
            relativePath: ""
        )
        let changed = NextcloudEntry(
            href: "/remote.php/dav/files/alice/Notes/",
            displayName: "Notes",
            etag: "new",
            fileID: "8",
            size: 0,
            modified: Date(timeIntervalSince1970: 1_700_000_100),
            isCollection: true,
            relativePath: "Notes"
        )
        let note = NextcloudEntry(
            href: "/remote.php/dav/files/alice/Notes/a.txt",
            displayName: "a.txt",
            etag: "f",
            fileID: "9",
            size: 4,
            modified: Date(timeIntervalSince1970: 1_700_000_100),
            isCollection: false,
            relativePath: "Notes/a.txt"
        )
        let walk = try await NextcloudWalker.walk(rootHref: root, previousEtags: ["/remote.php/dav/files/alice/Documents": "same"]) { href in
            let key = Nextcloud.normalize(href)
            if key.hasSuffix("/Notes") {
                return [changed, note]
            }
            XCTAssertFalse(key.hasSuffix("/Documents"), "unchanged folder was opened")
            return [rootEntry, docs, changed]
        }
        XCTAssertTrue(walk.items.contains { $0.remoteID == "9" && $0.relativePath == "Notes/a.txt" })
        XCTAssertEqual(walk.childrenByParent["1"], ["7", "8"])
        XCTAssertEqual(walk.etags["/remote.php/dav/files/alice/Documents"], "same")
    }

    func testS3ListSynthesizesFolders() throws {
        let parsed = try S3Listing.parse(Data(Fixtures.s3List.utf8))
        XCTAssertEqual(parsed.objects.map(\.key), ["photos/cat.jpg", "docs/readme.txt"])
        XCTAssertEqual(parsed.objects.first?.size, 2048)
        XCTAssertEqual(parsed.next, "token-2")
        XCTAssertTrue(parsed.truncated)
        let items = S3Listing.items(objects: parsed.objects, prefix: "")
        XCTAssertTrue(items.contains { $0.relativePath == "photos/cat.jpg" && $0.size == 2048 && $0.kind == .file })
        XCTAssertTrue(items.contains { $0.relativePath == "photos" && $0.kind == .folder })
        XCTAssertTrue(items.contains { $0.relativePath == "docs" && $0.kind == .folder })
    }

    func testSigV4MatchesAWSExample() {
        let signed = SigV4.sign(
            method: "GET",
            url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
            region: "us-east-1",
            headers: [
                "host": "examplebucket.s3.amazonaws.com",
                "range": "bytes=0-9",
            ],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            amzDate: "20130524T000000Z"
        )
        XCTAssertEqual(
            signed.signature,
            "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
        XCTAssertTrue(signed.canonicalRequest.contains("host;range;x-amz-content-sha256;x-amz-date"))
    }

    func testPKCEChallenge() {
        XCTAssertEqual(PKCEPair.challenge(for: "drivesearch-pkce-verifier"), "DfCY6X8oK3tEpJrzX35tH6xOppUfqlaVfphgsFFvzd8")
    }

    func testPathSanitizerCollapsesCase() {
        var items = [
            RemoteItem(remoteID: "a", name: "Readme", relativePath: "Readme", size: 1, modified: Date(timeIntervalSince1970: 1), kind: .file),
            RemoteItem(remoteID: "b", name: "readme", relativePath: "readme", size: 1, modified: Date(timeIntervalSince1970: 1), kind: .file),
        ]
        PathSanitizer.assign(&items)
        XCTAssertEqual(items[0].mirrorPath, "Readme")
        XCTAssertNotEqual(items[0].mirrorPath.lowercased(), items[1].mirrorPath.lowercased())
        XCTAssertEqual(PathSanitizer.sanitize("../etc/passwd"), "_/etc/passwd")
    }

    func testQueryComposerScopesAccounts() {
        let all = QueryComposer.fsearchQueries(userText: "report ext:pdf", universe: ["/m/a", "/m/b"], restrictTo: nil)
        XCTAssertEqual(all, ["report ext:pdf"])
        let one = QueryComposer.fsearchQueries(userText: "report ext:pdf", universe: ["/m/a", "/m/b"], restrictTo: ["/m/a"])
        XCTAssertEqual(one, ["report ext:pdf in:\"/m/a\""])
        let relative = QueryComposer.fsearchQueries(userText: "report in:Docs", universe: ["/m/a", "/m/b"], restrictTo: nil)
        XCTAssertEqual(relative, ["report in:\"/m/a/Docs\"", "report in:\"/m/b/Docs\""])
        let absolute = QueryComposer.fsearchQueries(userText: "in:\"/m/a/Docs\" size:>1mb", universe: ["/m/a"], restrictTo: nil)
        XCTAssertEqual(absolute, ["size:>1mb in:\"/m/a/Docs\""])
    }
}
