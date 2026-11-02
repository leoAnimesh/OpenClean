import Foundation

/// The last result of a slow listing (installed apps, login items), saved as JSON in `<support>/Cache/`
/// so a screen can show it at once while a fresh listing loads.
///
/// Display only: nothing is removed or changed on the strength of a cached value. Callers keep actions
/// disabled until the fresh listing arrives, and the files are untrusted input, so anything unreadable,
/// from another format version or under an unexpected name is simply treated as no cache.
public struct DisplayCache: Sendable {
    public enum Entry: String, Sendable, CaseIterable {
        case installedApps = "installed-apps"
        case loginItems = "login-items"
    }

    /// Bump when a cached type changes shape, so old files are ignored instead of misread.
    static let formatVersion = 1

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let savedAt: Date
        let value: Value
    }

    private func url(_ entry: Entry) -> URL { directory.appendingPathComponent(entry.rawValue + ".json") }

    /// The cached value and when it was saved, or nil if there is none or it can't be read.
    public func load<Value: Codable>(_ type: Value.Type, _ entry: Entry) -> (value: Value, savedAt: Date)? {
        guard let data = try? Data(contentsOf: url(entry)),
            let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data),
            envelope.version == Self.formatVersion
        else { return nil }
        return (envelope.value, envelope.savedAt)
    }

    /// Replaces the cached value. Failures are ignored: the cache only saves time.
    public func save<Value: Codable>(_ value: Value, _ entry: Entry, now: Date = Date()) {
        let envelope = Envelope(version: Self.formatVersion, savedAt: now, value: value)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url(entry), options: [.atomic])
    }
}
