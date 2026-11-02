import Foundation

/// Where a launchd property list lives, which decides whether OpenClean may act on it.
public enum LaunchItemScope: String, Sendable, Equatable, CaseIterable, Codable {
    /// `~/Library/LaunchAgents`: runs as you; Disable / Enable / Remove are offered.
    case user
    /// `/Library/LaunchAgents`: installed for every user by an administrator. Read-only in v1.
    case systemAgent
    /// `/Library/LaunchDaemons`: runs as root. Read-only in v1.
    case systemDaemon

    public var isActionable: Bool { self == .user }
}

public enum KeepAlive: Sendable, Equatable, Codable {
    case no
    case always
    /// A dictionary of conditions (e.g. `SuccessfulExit`, `NetworkState`).
    case conditional
}

/// The facts read from one launchd plist.
public struct LaunchItemDefinition: Sendable, Equatable, Codable {
    public var label: String
    /// `Program`, or the first element of `ProgramArguments`.
    public var program: String?
    public var arguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: KeepAlive
    /// The plist's own `Disabled` key (launchd's override database can say otherwise).
    public var disabledInPlist: Bool

    public init(
        label: String, program: String?, arguments: [String] = [], runAtLoad: Bool = false,
        keepAlive: KeepAlive = .no, disabledInPlist: Bool = false
    ) {
        self.label = label
        self.program = program
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.disabledInPlist = disabledInPlist
    }
}

public enum LaunchItemParseError: Error, Equatable, CustomStringConvertible {
    case unreadable
    case notADictionary
    case missingLabel

    public var description: String {
        switch self {
        case .unreadable: "not a valid property list"
        case .notADictionary: "the property list is not a dictionary"
        case .missingLabel: "the Label key is missing or empty"
        }
    }
}

public enum LaunchItemParser {
    /// Parses plist data (XML or binary). Missing optional keys take launchd's defaults.
    public static func parse(_ data: Data) throws -> LaunchItemDefinition {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw LaunchItemParseError.unreadable
        }
        guard let plist = object as? [String: Any] else { throw LaunchItemParseError.notADictionary }
        guard let label = plist["Label"] as? String, !label.isEmpty else { throw LaunchItemParseError.missingLabel }

        let arguments = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let program = (plist["Program"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? arguments.first
        let keepAlive: KeepAlive
        switch plist["KeepAlive"] {
        case let value as Bool: keepAlive = value ? .always : .no
        case is [String: Any]: keepAlive = .conditional
        default: keepAlive = .no
        }
        return LaunchItemDefinition(
            label: label, program: program, arguments: arguments,
            runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false, keepAlive: keepAlive,
            disabledInPlist: (plist["Disabled"] as? Bool) ?? false)
    }
}

/// Who installed a launch item, as far as we can tell.
public struct LaunchItemOwner: Sendable, Equatable, Codable {
    public enum Confidence: String, Sendable, Equatable, Codable {
        /// The program lives inside this app, or the label is this app's bundle identifier (or starts with it).
        case exact
        /// Same vendor prefix as an installed app (e.g. `com.google.*`).
        case likely
    }

    public var appName: String
    public var bundleID: String?
    public var bundlePath: String?
    public var confidence: Confidence

    public init(appName: String, bundleID: String?, bundlePath: String?, confidence: Confidence) {
        self.appName = appName
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.confidence = confidence
    }
}

public enum LoadState: Sendable, Equatable, Codable {
    case loaded(pid: Int32?)
    case notLoaded
    /// launchctl couldn't be asked or its output couldn't be read.
    case unknown

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// A launch agent or daemon with everything the UI shows.
public struct LaunchItem: Sendable, Equatable, Identifiable, Codable {
    public var path: String
    public var scope: LaunchItemScope
    public var definition: LaunchItemDefinition
    public var owner: LaunchItemOwner?
    public var loadState: LoadState
    /// Effective disabled state: launchd's override if it has one, otherwise the plist's `Disabled` key.
    public var isDisabled: Bool

    public var id: String { path }
    public var label: String { definition.label }

    public init(
        path: String, scope: LaunchItemScope, definition: LaunchItemDefinition, owner: LaunchItemOwner?,
        loadState: LoadState, isDisabled: Bool
    ) {
        self.path = path
        self.scope = scope
        self.definition = definition
        self.owner = owner
        self.loadState = loadState
        self.isDisabled = isDisabled
    }
}

/// A plist we found but couldn't use; shown so nothing is silently hidden.
public struct UnreadableLaunchItem: Sendable, Equatable, Identifiable, Codable {
    public var path: String
    public var scope: LaunchItemScope
    public var reason: String
    public var id: String { path }

    public init(path: String, scope: LaunchItemScope, reason: String) {
        self.path = path
        self.scope = scope
        self.reason = reason
    }
}

/// An app that ships a login item or launchd job inside its bundle (`SMAppService`). macOS manages
/// whether it's on in System Settings → General → Login Items; OpenClean only lists it.
public struct BundledBackgroundItem: Sendable, Equatable, Identifiable, Codable {
    public var appName: String
    public var bundlePath: String
    /// File names under `Contents/Library/LoginItems`, `LaunchAgents` and `LaunchDaemons`.
    public var items: [String]
    public var id: String { bundlePath }

    public init(appName: String, bundlePath: String, items: [String]) {
        self.appName = appName
        self.bundlePath = bundlePath
        self.items = items
    }
}

public struct LoginItemsInventory: Sendable, Equatable, Codable {
    public var items: [LaunchItem]
    public var unreadable: [UnreadableLaunchItem]
    public var bundled: [BundledBackgroundItem]
    /// False when launchctl state couldn't be read; load states are then `.unknown`.
    public var launchctlAvailable: Bool

    public init(
        items: [LaunchItem] = [], unreadable: [UnreadableLaunchItem] = [], bundled: [BundledBackgroundItem] = [],
        launchctlAvailable: Bool = true
    ) {
        self.items = items
        self.unreadable = unreadable
        self.bundled = bundled
        self.launchctlAvailable = launchctlAvailable
    }

    public func items(in scope: LaunchItemScope) -> [LaunchItem] { items.filter { $0.scope == scope } }
}
