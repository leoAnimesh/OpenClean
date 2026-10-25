import Foundation
import IOKit
import Metal

/// Reads the GPU driver's statistics from the I/O Registry. No root needed: the `IOAccelerator`
/// service publishes device-wide figures, and each Metal client below it publishes its process and
/// cumulative GPU time.
enum GPUStatistics {
    /// Metal's working-set limit doesn't change while the app runs, so the device is created once.
    static let workingSetLimit: UInt64? = MTLCreateSystemDefaultDevice().map { $0.recommendedMaxWorkingSetSize }

    /// Device-wide figures of the first GPU, or nil when there is none (e.g. a virtual machine).
    static func snapshot() -> GPUSnapshot? {
        var result: GPUSnapshot?
        forEachAccelerator { accelerator in
            guard result == nil,
                let statistics = property(accelerator, "PerformanceStatistics") as? [String: Any]
            else { return }
            result = snapshot(statistics: statistics, workingSetLimit: workingSetLimit)
        }
        return result
    }

    /// Cumulative GPU nanoseconds per pid, summed over every Metal client the process has open.
    static func timeByProcess() -> [Int32: UInt64] {
        var times: [Int32: UInt64] = [:]
        forEachAccelerator { accelerator in
            var iterator: io_iterator_t = 0
            guard
                IORegistryEntryCreateIterator(
                    accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
                    == KERN_SUCCESS
            else { return }
            defer { IOObjectRelease(iterator) }
            while case let client = IOIteratorNext(iterator), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                    let pid = pid(fromCreator: creator),
                    let usage = property(client, "AppUsage") as? [[String: Any]]
                else { continue }
                times[pid, default: 0] &+= gpuTime(appUsage: usage)
            }
        }
        return times
    }

    // MARK: Parsing (pure, tested)

    static func snapshot(statistics: [String: Any], workingSetLimit: UInt64?) -> GPUSnapshot {
        let utilization = (statistics["Device Utilization %"] as? NSNumber).map {
            min(1, max(0, $0.doubleValue / 100))
        }
        return GPUSnapshot(
            utilization: utilization,
            inUseBytes: (statistics["In use system memory"] as? NSNumber)?.uint64Value ?? 0,
            allocatedBytes: (statistics["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0,
            workingSetLimit: workingSetLimit)
    }

    /// "pid 171, WindowServer" → 171.
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isASCII && $0.isNumber }
        return Int32(digits)
    }

    /// Sum of `accumulatedGPUTime` (nanoseconds) over one client's command queues.
    static func gpuTime(appUsage: [[String: Any]]) -> UInt64 {
        appUsage.reduce(0) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
    }

    // MARK: I/O Registry

    private static func forEachAccelerator(_ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
