import FSearchKit
import Foundation
import ProviderKit

/// FSearchKit indexes real directories. Cloud metadata is mirrored as empty
/// (sparse) files so `size:`, `mtime:`, `ext:`, and `in:` use the engine as it
/// stands. Provider ids stay in the catalog. There is no metadata-ingest API
/// on this pinned fsearch commit, and this repo cannot publish one upstream.
actor IndexBridge: SearchRefreshing {
    private var engine: FSearch?
    private var roots: [String] = []
    private let indexDirectory: URL

    init(indexDirectory: URL) {
        self.indexDirectory = indexDirectory
    }

    func setRoots(_ roots: [URL]) async throws {
        let paths = roots.map { $0.resolvingSymlinksInPath().path }
        if paths == self.roots, engine != nil { return }
        await engine?.stop()
        engine = nil
        self.roots = paths
        let usable = roots.isEmpty ? [indexDirectory.deletingLastPathComponent()] : roots.map { $0.resolvingSymlinksInPath() }
        engine = try await FSearch(roots: usable, indexDirectory: indexDirectory)
        try await waitUntilReady()
    }

    func refresh() async throws {
        try await waitUntilReady()
        try await engine?.refresh()
    }

    func search(query: String, limit: Int) async throws -> [FSearchHit] {
        try await waitUntilReady()
        guard let engine else { throw ProviderError.transport("The index is not running.") }
        return try await engine.search(query: query, limit: limit)
    }

    func phase() async -> String {
        guard let engine else { return "idle" }
        let stream = await engine.progress(every: .milliseconds(100))
        for await event in stream {
            return event.phase.rawValue
        }
        return "idle"
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            guard let engine else { return }
            let stream = await engine.progress(every: .milliseconds(80))
            var event: FSearchProgress?
            for await next in stream {
                event = next
                break
            }
            if let event {
                let phase = event.phase.rawValue
                let settled = event.ready && (phase == "ready" || phase == "idle")
                if settled { return }
                if phase == "stopped" {
                    throw ProviderError.transport("The index stopped.")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
