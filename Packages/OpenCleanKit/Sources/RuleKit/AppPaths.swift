import Foundation

/// OpenClean's on-disk locations, rooted in `~/Library/Application Support/OpenClean`.
public struct AppPaths: Sendable, Equatable {
    public let support: URL

    public init(support: URL) {
        self.support = support
    }

    public static func standard(home: String) -> AppPaths {
        AppPaths(
            support: URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Application Support/OpenClean", isDirectory: true))
    }

    public var quarantine: URL { support.appendingPathComponent("Quarantine", isDirectory: true) }
    public var userRules: URL { support.appendingPathComponent("rules", isDirectory: true) }
    public var settingsFile: URL { support.appendingPathComponent("settings.json") }
    /// Display-only copies of slow listings (see `DisplayCache`).
    public var cache: URL { support.appendingPathComponent("Cache", isDirectory: true) }
}
