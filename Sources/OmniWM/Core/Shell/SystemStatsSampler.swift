// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import IOKit

struct CPUTicks: Equatable, Sendable {
    var busy: UInt64
    var idle: UInt64
}

struct CPUMeter {
    static let window: TimeInterval = 0.5

    private var previous: (ticks: CPUTicks, time: TimeInterval)?

    func isDue(at time: TimeInterval) -> Bool {
        previous.map { time - $0.time >= Self.window } ?? true
    }

    mutating func usage(of ticks: CPUTicks?, at time: TimeInterval) -> Double? {
        defer { previous = ticks.map { ($0, time) } }
        return SystemStatsSampler.cpuUsage(previous: previous?.ticks, current: ticks)
    }

    mutating func reset() {
        previous = nil
    }
}

enum MemoryPressureLevel: String, Equatable, Sendable {
    case normal
    case warning
    case critical
}

struct SystemStatsHostInfo: Equatable, Sendable {
    let chip: String
    let modelIdentifier: String
    let osVersion: String
    let hostname: String
}

enum SystemStatsSampler {
    nonisolated static func cpuUsage(previous: CPUTicks?, current: CPUTicks?) -> Double? {
        guard let previous, let current else { return nil }
        let busy = current.busy &- previous.busy
        let idle = current.idle &- previous.idle
        let total = busy &+ idle
        guard total > 0, busy <= total else { return nil }
        return Double(busy) / Double(total)
    }

    nonisolated static func memoryUsed(
        activePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        (activePages + wiredPages + compressedPages) * pageSize
    }

    nonisolated static func pressureLevel(fromSysctlValue value: Int32?) -> MemoryPressureLevel? {
        switch value {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }

    static func currentCPUTicks() -> CPUTicks? {
        var processorCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &infoArray,
            &infoCount
        )
        guard result == KERN_SUCCESS, let infoArray else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: infoArray)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }
        var busy: UInt64 = 0
        var idle: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0 ..< Int(processorCount) {
            let base = cpu * states
            busy += UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)]))
            busy += UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)]))
            busy += UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)]))
            idle += UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)]))
        }
        return CPUTicks(busy: busy, idle: idle)
    }

    static func memorySample() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let used = memoryUsed(
            activePages: UInt64(stats.active_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(max(sysconf(_SC_PAGESIZE), 1))
        )
        return (used, total)
    }

    static func memoryPressure() -> MemoryPressureLevel? {
        pressureLevel(fromSysctlValue: rawMemoryPressure())
    }

    private static func rawMemoryPressure() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }

    static func gpuUtilization() -> Double? {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dictionary["PerformanceStatistics"] as? [String: Any],
                  let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            else {
                continue
            }
            return min(max(utilization / 100, 0), 1)
        }
        return nil
    }

    static func uptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    static func networkBytes() -> (received: UInt64, sent: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { bytes in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length
                {
                    let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0 {
                        received &+= message.ifm_data.ifi_ibytes
                        sent &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    static func diskSample() -> (used: Int64, total: Int64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
            let total = values.volumeTotalCapacity
        else {
            return (0, 0)
        }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        return (Int64(total) - available, Int64(total))
    }

    static func hostInfo() -> SystemStatsHostInfo {
        SystemStatsHostInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
