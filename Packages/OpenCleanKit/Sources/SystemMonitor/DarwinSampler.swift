import Darwin
import Foundation

/// Reads counters straight from the kernel: mach host statistics, sysctl, libproc and the I/O Registry.
/// No subprocesses. Process sampling covers the current user's processes only (others need root).
public struct DarwinSampler: SystemSampler {
    let volume: URL
    let currentUID: UInt32
    let timebase: (numer: UInt64, denom: UInt64)

    public init(volume: URL = URL(fileURLWithPath: NSHomeDirectory()), currentUID: UInt32 = getuid()) {
        self.volume = volume
        self.currentUID = currentUID
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }

    public func sample(_ request: SampleRequest) -> RawSample {
        var sample = RawSample(time: ProcessInfo.processInfo.systemUptime)
        if request.contains(.metrics) {
            sample.cpu = Self.cpuTicks()
            sample.memory = Self.memory()
            sample.network = Self.networkCounters()
            sample.disk = disk()
            sample.gpu = GPUStatistics.snapshot()
        }
        if request.contains(.processes) {
            sample.processes = processes()
        }
        return sample
    }

    // MARK: CPU

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(
            user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }

    // MARK: Memory

    static func memory() -> MemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(max(sysconf(_SC_PAGESIZE), 4096))
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure: MemoryPressure =
            sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
            ? MemoryPressure(sysctlLevel: level) : .unknown
        return MemorySnapshot(
            physical: ProcessInfo.processInfo.physicalMemory,
            free: UInt64(stats.free_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            internal: UInt64(stats.internal_page_count) * page,
            purgeable: UInt64(stats.purgeable_count) * page,
            pressure: pressure)
    }

    // MARK: Network

    /// Sums 64-bit interface counters (`NET_RT_IFLIST2`); `getifaddrs` only has 32-bit ones that wrap at 4 GB.
    static func networkCounters() -> NetworkCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                    offset + MemoryLayout<if_msghdr2>.size <= length,
                    (header.ifm_flags & IFF_LOOPBACK) == 0
                {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    received &+= info.ifm_data.ifi_ibytes
                    sent &+= info.ifm_data.ifi_obytes
                }
                offset += messageLength
            }
        }
        return NetworkCounters(received: received, sent: sent)
    }

    // MARK: Disk

    func disk() -> DiskSnapshot? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
            let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else { return nil }
        return DiskSnapshot(available: available, total: Int64(total))
    }

    // MARK: Processes

    func processes() -> [ProcessSample] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        let gpuTimes = GPUStatistics.timeByProcess()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(Int(count))
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var short = proc_bsdshortinfo()
            let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else { continue }
            guard short.pbsi_uid == currentUID else { continue }

            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }

            var path: String?
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if pathLength > 0 {
                path = String(
                    decoding: pathBuffer.prefix(Int(pathLength)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self)
            }
            let comm = withUnsafeBytes(of: short.pbsi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let name = path.map { ($0 as NSString).lastPathComponent } ?? comm
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            samples.append(
                ProcessSample(
                    pid: pid, uid: short.pbsi_uid, name: name.isEmpty ? comm : name, path: path,
                    cpuTimeNanoseconds: ticks.multipliedReportingOverflow(by: timebase.numer).partialValue
                        / timebase.denom,
                    residentBytes: usage.ri_phys_footprint, gpuTimeNanoseconds: gpuTimes[pid] ?? 0))
        }
        return samples
    }
}
