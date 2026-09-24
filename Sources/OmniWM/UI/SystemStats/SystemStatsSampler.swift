// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import IOKit

struct CPUTicks: Equatable, Sendable {
    var busy: UInt64
    var idle: UInt64
}

enum MemoryPressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical

    var displayName: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }
}

struct SystemStatsHostInfo: Equatable, Sendable {
    let chip: String
    let modelIdentifier: String
    let osVersion: String
    let hostname: String
    let resolutions: [String]
}

struct SystemStatsSnapshot: Equatable, Sendable {
    var cpuUsage: Double?
    var ramUsedBytes: UInt64
    var ramTotalBytes: UInt64
    var memoryPressure: MemoryPressureLevel?
    var gpuUtilization: Double?
    var diskUsedBytes: Int64
    var diskTotalBytes: Int64
    var uptime: TimeInterval
    var host: SystemStatsHostInfo
}

struct SystemStatsSampler: Sendable {
    private var previousTicks: CPUTicks?
    private let displayResolutions: [String]
    private var hostInfo: SystemStatsHostInfo?

    init(displayResolutions: [String] = []) {
        self.displayResolutions = displayResolutions
    }

    mutating func sample() -> SystemStatsSnapshot {
        let ticks = Self.currentCPUTicks()
        let cpu = Self.cpuUsage(previous: previousTicks, current: ticks)
        previousTicks = ticks
        let memory = Self.memorySample()
        let disk = Self.diskSample()
        let info = hostInfo ?? Self.makeHostInfo(displayResolutions: displayResolutions)
        hostInfo = info
        return SystemStatsSnapshot(
            cpuUsage: cpu,
            ramUsedBytes: memory.used,
            ramTotalBytes: memory.total,
            memoryPressure: Self.pressureLevel(fromSysctlValue: Self.rawMemoryPressure()),
            gpuUtilization: Self.gpuUtilization(),
            diskUsedBytes: disk.used,
            diskTotalBytes: disk.total,
            uptime: ProcessInfo.processInfo.systemUptime,
            host: info
        )
    }

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

    private static func currentCPUTicks() -> CPUTicks? {
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

    private static func memorySample() -> (used: UInt64, total: UInt64) {
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

    private static func rawMemoryPressure() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }

    private static func gpuUtilization() -> Double? {
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

    private static func diskSample() -> (used: Int64, total: Int64) {
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

    private static func makeHostInfo(displayResolutions: [String]) -> SystemStatsHostInfo {
        SystemStatsHostInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            resolutions: displayResolutions
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

enum SystemStatsRefreshStream {
    nonisolated static func stream(displayResolutions: [String]) -> AsyncStream<SystemStatsSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var sampler = SystemStatsSampler(displayResolutions: displayResolutions)
                while !Task.isCancelled {
                    continuation.yield(sampler.sample())
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
