import Foundation

/// One process with its CPU and GPU use over the last interval.
public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String?
    /// Percent of one core, as Activity Monitor shows it (a busy 4-thread process can exceed 100).
    public var cpuPercent: Double
    public var residentBytes: UInt64
    /// Percent of the GPU's time spent on this process's work.
    public var gpuPercent: Double

    public var id: Int32 { pid }

    public init(
        pid: Int32, uid: UInt32, name: String, path: String?, cpuPercent: Double, residentBytes: UInt64,
        gpuPercent: Double = 0
    ) {
        self.pid = pid
        self.uid = uid
        self.name = name
        self.path = path
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.gpuPercent = gpuPercent
    }
}

/// Processes that belong to one app bundle (helpers included), or a single bundle-less process.
public struct ProcessGroup: Sendable, Equatable, Identifiable {
    /// The bundle path, or "pid:<n>" for a process outside any app.
    public var id: String
    public var name: String
    public var bundlePath: String?
    /// The app's own executable process, used for Quit; nil when only helpers are running.
    public var mainPID: Int32?
    public var processes: [ProcessUsage]
    public var cpuPercent: Double
    public var residentBytes: UInt64
    public var gpuPercent: Double
    /// True when the library's policy allows offering Quit / Force Quit. The app layer still requires
    /// an `NSRunningApplication` for `mainPID`.
    public var canQuit: Bool
    /// A lone background process (not inside an app) that belongs to the user and isn't protected by
    /// the policy. The app layer may force quit it through `ProcessTerminator`, which re-verifies it.
    public var killableProcess: ProcessUsage?

    public init(
        id: String, name: String, bundlePath: String?, mainPID: Int32?, processes: [ProcessUsage],
        cpuPercent: Double, residentBytes: UInt64, gpuPercent: Double = 0, canQuit: Bool,
        killableProcess: ProcessUsage? = nil
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.mainPID = mainPID
        self.processes = processes
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.gpuPercent = gpuPercent
        self.canQuit = canQuit
        self.killableProcess = killableProcess
    }
}

public enum ProcessUsageCalculator {
    /// Per-process CPU and GPU % from two samples `interval` seconds apart. Processes new since the
    /// previous sample (or whose pid was reused with a lower CPU time) report 0 for this interval.
    public static func usage(previous: [ProcessSample], current: [ProcessSample], interval: TimeInterval)
        -> [ProcessUsage]
    {
        let before = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let wallNanoseconds = interval * 1_000_000_000
        return current.map { sample in
            var percent = 0.0
            var gpuPercent = 0.0
            if wallNanoseconds > 0, let old = before[sample.pid], old.name == sample.name,
                sample.cpuTimeNanoseconds >= old.cpuTimeNanoseconds
            {
                percent = Double(sample.cpuTimeNanoseconds - old.cpuTimeNanoseconds) / wallNanoseconds * 100
                // A Metal client closing makes the sum go down; that interval counts as 0.
                if sample.gpuTimeNanoseconds >= old.gpuTimeNanoseconds {
                    gpuPercent = Double(sample.gpuTimeNanoseconds - old.gpuTimeNanoseconds) / wallNanoseconds * 100
                }
            }
            return ProcessUsage(
                pid: sample.pid, uid: sample.uid, name: sample.name, path: sample.path, cpuPercent: percent,
                residentBytes: sample.residentBytes, gpuPercent: gpuPercent)
        }
    }

    /// Groups processes by their outermost `.app` bundle, so helpers count toward their app.
    public static func group(_ usages: [ProcessUsage], policy: ForceQuitPolicy) -> [ProcessGroup] {
        var order: [String] = []
        var members: [String: [ProcessUsage]] = [:]
        var bundles: [String: String] = [:]
        for usage in usages {
            let bundle = usage.path.flatMap(outermostAppBundle)
            let key = bundle ?? "pid:\(usage.pid)"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(usage)
            if let bundle { bundles[key] = bundle }
        }
        return order.map { key in
            let processes = members[key] ?? []
            let bundle = bundles[key]
            let main = bundle.flatMap { bundle in
                processes.first { $0.path.map { isMainExecutable($0, of: bundle) } ?? false }
            }
            let name: String
            if let bundle {
                name = appName(fromBundlePath: bundle)
            } else {
                name = processes.first?.name ?? key
            }
            let canQuit = bundle != nil && main.map { !policy.isProtected($0) } == true
            let killable =
                bundle == nil && processes.count == 1 && processes[0].path != nil
                    && !policy.isProtected(processes[0]) ? processes[0] : nil
            return ProcessGroup(
                id: key, name: name, bundlePath: bundle, mainPID: main?.pid,
                processes: processes.sorted { $0.cpuPercent > $1.cpuPercent },
                cpuPercent: processes.reduce(0) { $0 + $1.cpuPercent },
                residentBytes: processes.reduce(0) { $0 + $1.residentBytes },
                gpuPercent: processes.reduce(0) { $0 + $1.gpuPercent }, canQuit: canQuit,
                killableProcess: killable)
        }
    }

    public static func topByCPU(_ groups: [ProcessGroup], limit: Int) -> [ProcessGroup] {
        Array(
            groups.sorted {
                $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.residentBytes > $1.residentBytes
            }
            .prefix(limit))
    }

    public static func topByMemory(_ groups: [ProcessGroup], limit: Int) -> [ProcessGroup] {
        Array(groups.sorted { $0.residentBytes > $1.residentBytes }.prefix(limit))
    }

    public static func topByGPU(_ groups: [ProcessGroup], limit: Int) -> [ProcessGroup] {
        Array(
            groups.sorted {
                $0.gpuPercent != $1.gpuPercent ? $0.gpuPercent > $1.gpuPercent : $0.cpuPercent > $1.cpuPercent
            }
            .prefix(limit))
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Bar.app/Contents/MacOS/Bar" → "/Applications/Foo.app".
    /// Byte-level: a ".app/" component boundary, never grapheme-based string matching.
    public static func outermostAppBundle(_ path: String) -> String? {
        let bytes = Array(path.utf8)
        let marker = Array(".app/".utf8)
        guard bytes.first == 0x2F, bytes.count > marker.count else { return nil }
        var index = 1
        while index + marker.count <= bytes.count {
            if bytes[index..<(index + marker.count)].elementsEqual(marker), bytes[index - 1] != 0x2F {
                return String(decoding: bytes[..<(index + 4)], as: UTF8.self)
            }
            index += 1
        }
        return nil
    }

    /// True when `path` is `<bundle>/Contents/MacOS/<file>` exactly.
    static func isMainExecutable(_ path: String, of bundle: String) -> Bool {
        let prefix = Array((bundle + "/Contents/MacOS/").utf8)
        let bytes = Array(path.utf8)
        guard bytes.count > prefix.count, bytes[..<prefix.count].elementsEqual(prefix) else { return false }
        return !bytes[prefix.count...].contains(0x2F)
    }

    static func appName(fromBundlePath bundle: String) -> String {
        let last = (bundle as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}
