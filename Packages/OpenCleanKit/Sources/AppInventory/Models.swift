import Foundation
import RuleKit
import ScanEngine

/// A folder whose `*.app` entries are listed. Only folders with `allowsUninstall` can lose an app.
public struct ApplicationFolder: Sendable, Hashable {
    public let path: String
    public let allowsUninstall: Bool

    public init(path: String, allowsUninstall: Bool) {
        self.path = path
        self.allowsUninstall = allowsUninstall
    }

    /// `/Applications`, `/Applications/Utilities` (listing only) and `<home>/Applications`.
    public static func standard(home: String) -> [ApplicationFolder] {
        [
            ApplicationFolder(path: "/Applications", allowsUninstall: true),
            ApplicationFolder(path: "/Applications/Utilities", allowsUninstall: false),
            ApplicationFolder(path: home + "/Applications", allowsUninstall: true),
        ]
    }
}

/// Why an app can or cannot be uninstalled. Running state is tracked separately because it changes.
public enum AppStatus: String, Sendable, Hashable, Codable {
    case removable
    case appleApp
    case openClean
    case needsAdministrator
    case listOnly
    case noBundleID

    /// The Uninstaller can move this app to quarantine: either directly (`.removable`) or after the user
    /// types an administrator password (`.needsAdministrator`). Everything else is never removed.
    public var isRemovable: Bool { self == .removable || self == .needsAdministrator }

    /// The bundle is owned by root or not writable by the user, so uninstalling it needs an administrator
    /// password (one `AppBundleAdminMove`).
    public var requiresAdministrator: Bool { self == .needsAdministrator }

    public var explanation: String {
        switch self {
        case .removable: "Can be moved to quarantine"
        case .appleApp: "Apple app — part of macOS, never removed"
        case .openClean: "This is OpenClean itself"
        case .needsAdministrator: "Needs your administrator password to uninstall"
        case .listOnly: "In Utilities — listed for information only"
        case .noBundleID: "Has no bundle identifier, so it can't be checked safely"
        }
    }
}

public struct InstalledApp: Sendable, Hashable, Identifiable, Codable {
    public static let openCleanBundleID = "com.openclean"

    public var id: String { path }
    /// Canonical (`realpath`'d) path of the `.app` bundle.
    public let path: String
    public let name: String
    /// `CFBundleName` when it differs from the file name; used for exact name matching of leftovers.
    public let bundleName: String?
    public let bundleID: String?
    public let version: String?
    public let size: Int64
    public let device: Int32
    public let inode: UInt64
    public let modificationDate: Date
    public let ownerUID: UInt32
    public let isRunning: Bool
    public let isWritable: Bool
    public let lastUsed: Date?
    public let status: AppStatus

    public init(
        path: String, name: String, bundleName: String? = nil, bundleID: String?, version: String?, size: Int64,
        device: Int32, inode: UInt64, modificationDate: Date, ownerUID: UInt32, isRunning: Bool,
        isWritable: Bool, lastUsed: Date?, status: AppStatus
    ) {
        self.path = path
        self.name = name
        self.bundleName = bundleName
        self.bundleID = bundleID
        self.version = version
        self.size = size
        self.device = device
        self.inode = inode
        self.modificationDate = modificationDate
        self.ownerUID = ownerUID
        self.isRunning = isRunning
        self.isWritable = isWritable
        self.lastUsed = lastUsed
        self.status = status
    }

    /// Names used for exact (case-insensitive) matching of leftover folders.
    public var matchNames: [String] {
        var names = [name]
        if let bundleName, canonicalNameKey(bundleName) != canonicalNameKey(name) { names.append(bundleName) }
        return names
    }

    /// The inventory snapshot as a scan item, so pre-delete checks catch changes made after listing.
    public func scanItem(ruleID: String) -> ScanItem {
        ScanItem(
            path: path, ruleID: ruleID, size: size, device: device, inode: inode,
            modificationDate: modificationDate, ownerUID: ownerUID, reportOnly: !status.isRemovable)
    }
}

public enum LeftoverKind: String, Sendable, Hashable, CaseIterable {
    case applicationSupport, caches, preferences, containers, groupContainers, savedState, logs
    case httpStorages, webKit, applicationScripts, launchAgents, cookies, launchDaemons, privilegedHelpers

    public var displayName: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedState: "Saved Application State"
        case .logs: "Logs"
        case .httpStorages: "HTTP Storage"
        case .webKit: "WebKit Data"
        case .applicationScripts: "Application Scripts"
        case .launchAgents: "Launch Agents"
        case .cookies: "Cookies"
        case .launchDaemons: "Launch Daemons"
        case .privilegedHelpers: "Privileged Helpers"
        }
    }
}

public enum LeftoverMatch: String, Sendable, Hashable {
    /// The entry is named after the bundle identifier.
    case bundleID
    /// The entry's name equals the app's name exactly (case-insensitive).
    case name
}

public enum LeftoverScope: String, Sendable, Hashable {
    /// Inside the user's `~/Library`; can be moved to quarantine.
    case user
    /// Inside `/Library`; shown for information only in this version.
    case system
}

public struct Leftover: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: LeftoverKind
    public let match: LeftoverMatch
    public let scope: LeftoverScope
    public let size: Int64
    public let device: Int32
    public let inode: UInt64
    public let modificationDate: Date
    public let ownerUID: UInt32
    public let isDirectory: Bool

    public init(
        path: String, kind: LeftoverKind, match: LeftoverMatch, scope: LeftoverScope, size: Int64, device: Int32,
        inode: UInt64, modificationDate: Date, ownerUID: UInt32, isDirectory: Bool
    ) {
        self.path = path
        self.kind = kind
        self.match = match
        self.scope = scope
        self.size = size
        self.device = device
        self.inode = inode
        self.modificationDate = modificationDate
        self.ownerUID = ownerUID
        self.isDirectory = isDirectory
    }

    public var isReportOnly: Bool { scope == .system }
    /// Bundle-id matches are ticked by default; name matches need the user's opt-in.
    public var isSelectedByDefault: Bool { scope == .user && match == .bundleID }

    public func scanItem(ruleID: String) -> ScanItem {
        ScanItem(
            path: path, ruleID: ruleID, size: size, device: device, inode: inode,
            modificationDate: modificationDate, ownerUID: ownerUID, reportOnly: isReportOnly)
    }
}

public struct AppInventoryProgress: Sendable, Equatable {
    public let finished: Int
    public let total: Int

    public init(finished: Int, total: Int) {
        self.finished = finished
        self.total = total
    }

    public var fraction: Double { total == 0 ? 0 : Double(finished) / Double(total) }
}

/// Case-folded, NFD bytes of a single file name; equal keys mean the same name on APFS.
func canonicalNameKey(_ name: String) -> [UInt8] {
    Array(canonicalPathKey("/" + name).dropFirst())
}

/// A non-empty single path component that is not `.` or `..` and has no NUL.
func isSafeComponent(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(0x2F) && !name.utf8.contains(0)
}
