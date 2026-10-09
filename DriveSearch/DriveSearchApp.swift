import BackgroundTasks
import Foundation
import ProviderKit
import SwiftUI

enum AppPaths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DriveSearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var mirror: URL {
        let url = support.appendingPathComponent("mirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var index: URL {
        support.appendingPathComponent("index", isDirectory: true)
    }

    static var catalog: URL {
        support.appendingPathComponent("catalog.sqlite")
    }

    static var quickLook: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum ClientConfigLoader {
    static func load() -> OAuthClientConfig {
        func value(_ key: String) -> String {
            let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
            if raw.isEmpty || raw.contains("$(") { return "" }
            return raw
        }
        let scheme = value("GoogleURLScheme")
        return OAuthClientConfig(
            googleClientID: value("GoogleClientID"),
            googleURLScheme: scheme.isEmpty ? "drivesearch-google" : scheme,
            microsoftClientID: value("MicrosoftClientID"),
            dropboxAppKey: value("DropboxAppKey")
        )
    }
}

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let model: AppModel

    private init() {
        model = AppModel()
    }
}

@main
struct DriveSearchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppRuntime.shared.model)
                .task { await AppRuntime.shared.model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await AppRuntime.shared.model.foreground() }
                }
        }
    }
}

enum BackgroundRefresh {
    static let identifier = "dev.wckdboy.drivesearch.refresh"
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { @MainActor in
                await AppRuntime.shared.model.backgroundSync()
            }
            refresh.expirationHandler = { work.cancel() }
            Task {
                _ = await work.result
                refresh.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
