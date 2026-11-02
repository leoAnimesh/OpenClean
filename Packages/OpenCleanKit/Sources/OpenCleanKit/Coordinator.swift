import Foundation
import Permissions
import Privilege
import Probes
import ProcessKit
import Quarantine
import RuleKit
import ScanEngine
import Updater

/// The single entry point the app and the CLI use. Holds no mutable state.
public struct OpenCleanCoordinator: Sendable {
    public let home: String
    /// `home` with symlinks resolved; every safety check (deny-list, linter, path expansion) uses this,
    /// because scan items are canonical paths.
    let resolvedHome: String
    public let paths: AppPaths
    public let registry: ProbeRegistry
    public let bundledRulesDirectory: URL?
    let processChecker: any ProcessChecker
    let openFiles: any OpenFilesProvider
    let admin: any AdminExecutor
    /// Moves a root-owned app bundle into quarantine for the Uninstaller (one password prompt per app).
    let bundleAdmin: (any AppBundleAdminExecutor)?
    let accessCheck: @Sendable () -> FullDiskAccessStatus
    let trash: TrashOperation
    /// Where update checks go: the GitHub API, or `OPENCLEAN_UPDATE_FEED` (dev override, allows file://).
    public let updateFeedURL: URL
    public let updateHostPolicy: UpdateHostPolicy

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registry: ProbeRegistry = .standard,
        processChecker: any ProcessChecker = RunningProcessChecker(),
        openFiles: any OpenFilesProvider = LsofOpenFilesProvider(),
        admin: any AdminExecutor = OsascriptAdminExecutor(),
        bundleAdmin: (any AppBundleAdminExecutor)? = nil,
        fullDiskAccess: (@Sendable () -> FullDiskAccessStatus)? = nil,
        trash: @escaping TrashOperation = Remover.systemTrash
    ) {
        let givenHome = environment["OPENCLEAN_HOME"] ?? home
        self.home = givenHome
        let resolvedHome = realPath(givenHome) ?? givenHome
        self.resolvedHome = resolvedHome
        // Resolved, so the quarantine store, settings and Updates paths compare equal to the realpath'd
        // forms the safety checks use (e.g. `AppBundleAdminMove` requires a symlink-free `items/`).
        paths = AppPaths.standard(home: resolvedHome)
        self.registry = registry
        bundledRulesDirectory = RulesLocator.bundledDirectory(environment: environment)
        self.processChecker = processChecker
        self.openFiles = openFiles
        self.admin = admin
        // Defaults to the same executor, so a fake `admin` in tests can never lead to a real prompt.
        self.bundleAdmin = bundleAdmin ?? (admin as? any AppBundleAdminExecutor)
        accessCheck = fullDiskAccess ?? { FullDiskAccessChecker(home: resolvedHome).status() }
        self.trash = trash
        (updateFeedURL, updateHostPolicy) = ReleaseFeed.source(environment: environment)
    }

    public var settingsStore: SettingsStore { SettingsStore(url: paths.settingsFile) }
    public var displayCache: DisplayCache { DisplayCache(directory: paths.cache) }
    public var store: QuarantineStore { QuarantineStore(root: paths.quarantine) }
    /// The home every check uses (`OPENCLEAN_HOME` if set), symlinks resolved.
    public var canonicalHome: String { resolvedHome }

    public func fullDiskAccessStatus() -> FullDiskAccessStatus { accessCheck() }

    public func makeLinter() -> RuleLinter { RuleLinter(home: resolvedHome, knownProbes: registry.ids) }

    public func loadRules(includeCaution: Bool) -> LoadedRules {
        var directories: [URL] = []
        if let bundledRulesDirectory { directories.append(bundledRulesDirectory) }
        directories.append(paths.userRules)
        var loaded = RuleCatalog.load(directories: directories, linter: makeLinter())
        if bundledRulesDirectory == nil {
            loaded.problems.insert("Bundled rule packs were not found. Reinstall, or set OPENCLEAN_RULES_DIR.", at: 0)
        }
        if !includeCaution { loaded.rules.removeAll { $0.safety == .caution } }
        return loaded
    }

    public func scan(
        _ rules: [Rule], settings: Settings, progress: AsyncStream<ScanProgress>.Continuation? = nil
    ) async -> ScanResult {
        let context = ScanContext(
            home: resolvedHome, hasFullDiskAccess: accessCheck() == .granted, processChecker: processChecker,
            userExcludes: resolved(settings.excludedPaths), projectFolders: resolved(settings.projectFolders))
        return await ScanEngine(registry: registry).scan(rules, context: context, progress: progress)
    }

    /// Settings paths with `~` expanded and symlinks resolved, the form every check compares against.
    func resolved(_ paths: [String]) -> [String] {
        let expander = PathExpander(home: resolvedHome)
        return paths.map { path -> String in
            let expanded = expander.expand(path)
            return realPath(expanded) ?? expanded
        }
    }

    /// Why `path` can't be added under Settings → Project folders, in plain words, or nil if it can.
    public func projectFolderProblem(_ path: String) -> String? {
        guard let folder = resolved([path]).first, realPath(folder) != nil else { return "That folder doesn't exist." }
        if canonicalPathKey(folder) == canonicalPathKey(resolvedHome) {
            return "Your home folder is already searched. Choose a folder inside it, such as Documents/Code."
        }
        guard ProjectFolderExemption.problem(with: folder, home: resolvedHome) == nil else {
            return
                "Choose a folder inside your home folder, on the same disk, that isn't protected (Library, iCloud Drive, .ssh and similar)."
        }
        return nil
    }

    /// Removes the plan's items. The pre-delete checks use the project folders saved right now, not the
    /// ones from the scan: removing a folder from Settings withdraws its exemption immediately.
    public func execute(_ plan: CleanupPlan) throws -> RemovalReport {
        let openPaths = try? openFiles.openPaths()
        let projectFolders = ProjectFolderExemption(
            home: resolvedHome, folders: resolved(settingsStore.load().projectFolders))
        let checker = PreDeleteChecker(
            denyList: DenyList(home: resolvedHome), processChecker: processChecker, openPaths: openPaths,
            projectFolders: projectFolders)
        return try Remover(store: store, checker: checker, admin: admin, trash: trash).remove(plan.requests)
    }

    public func history() -> [SessionListing] { store.listSessions() }

    public func restore(sessionID: String, paths: Set<String>? = nil, onConflict: ConflictPolicy) throws
        -> RestoreReport
    {
        try RestoreService(store: store, trash: trash).restore(
            sessionID: sessionID, paths: paths, onConflict: onConflict)
    }

    @discardableResult
    public func purgeExpired(settings: Settings) -> [String] {
        Purger(store: store).purge(retentionDays: settings.clampedRetentionDays)
    }

    public func purgeSchedule() -> PurgeSchedule { PurgeSchedule(home: home) }
}
