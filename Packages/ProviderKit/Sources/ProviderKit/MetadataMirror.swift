import Darwin
import Foundation

public enum MetadataMirror {
    /// Write stub files and directories for `items` under `accountRoot` and remove stubs that are no longer listed.
    /// File bytes are not downloaded. `ftruncate` sets the logical size; on APFS that is a sparse hole.
    public static func apply(accountRoot: URL, items: [RemoteItem]) throws {
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        let ordered = items.sorted { $0.mirrorPath.count < $1.mirrorPath.count }
        var desired: Set<String> = []
        for item in ordered {
            let relative = PathSanitizer.sanitize(item.mirrorPath)
            desired.insert(relative)
            try write(accountRoot: accountRoot, relative: relative, item: item)
        }
        try prune(accountRoot: accountRoot, keeping: desired)
    }

    static func write(accountRoot: URL, relative: String, item: RemoteItem) throws {
        let url = try url(accountRoot: accountRoot, relative: relative)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        switch item.kind {
        case .folder:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: item.modified], ofItemAtPath: url.path)
        case .file:
            try writeFile(url, size: item.size, modified: item.modified)
        }
    }

    static func writeFile(_ url: URL, size: UInt64, modified: Date) throws {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
           values.isRegularFile == true,
           values.fileSize.map(UInt64.init) == size,
           let existing = values.contentModificationDate,
           abs(existing.timeIntervalSince(modified)) < 2 {
            return
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o644))
        if fd < 0 {
            throw ProviderError.transport("Could not create a mirror file at \(url.lastPathComponent).")
        }
        defer { close(fd) }
        let length = off_t(min(size, UInt64(Int64.max)))
        if ftruncate(fd, length) != 0 {
            throw ProviderError.transport("Could not set the mirror size for \(url.lastPathComponent).")
        }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    static func prune(accountRoot: URL, keeping: Set<String>) throws {
        let root = accountRoot.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: accountRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var existing: [String] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            existing.append(relative)
        }
        for relative in existing.sorted(by: { $0.count > $1.count }) {
            if keeping.contains(relative) { continue }
            if keeping.contains(where: { $0.hasPrefix(relative + "/") }) { continue }
            let url = try url(accountRoot: accountRoot, relative: relative)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func url(accountRoot: URL, relative: String) throws -> URL {
        var url = accountRoot
        for part in relative.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(part)
            if name == "." || name == ".." {
                throw ProviderError.invalidPath
            }
            url.appendPathComponent(name)
        }
        let root = accountRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path != root && !path.hasPrefix(root + "/") {
            throw ProviderError.invalidPath
        }
        return url
    }
}
