// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreAudio
import IOKit.ps

extension ShellDataFeed {
    func updateBattery() {
        let wanted = !paused && (demands(.battery) || demands(.charging) || demands(.power))
        guard wanted != observesPowerSources else {
            if wanted, (data.power != nil) != demands(.power) {
                sampleBattery()
            }
            return
        }
        if wanted {
            sampleBattery()
            observePowerSources()
        } else {
            removePowerSource()
        }
    }

    private func sampleProviders() {
        let wantsDisk = demands(.disk) || demands(.system)
        let readsDisk = wantsDisk && (!diskWanted || diskBytes == nil || tick.isMultiple(of: 30))
        if sampleSlowly(gpu: demands(.gpu), disk: readsDisk) || !readsDisk {
            diskWanted = wantsDisk
        }
        data.disk = diskPercent
        let history = demands(.networkHistory)
        guard demands(.network) || history, let bytes = SystemStatsSampler.networkBytes() else {
            data.network = nil
            data.networkHistory = nil
            previousNetwork = nil
            return
        }
        var samples = history ? data.networkHistory ?? ShellNetworkHistory() : nil
        samples?.received = bytes.received
        samples?.sent = bytes.sent
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = previousNetwork, now > previous.time {
            let elapsed = now - previous.time
            let rate = ShellNetworkRate(
                down: (Double(bytes.received &- previous.bytes.received) / elapsed).rounded(),
                up: (Double(bytes.sent &- previous.bytes.sent) / elapsed).rounded()
            )
            data.network = demands(.network) ? rate : nil
            samples?.append(rate)
        }
        data.networkHistory = samples
        previousNetwork = (bytes, now)
    }

    private var diskPercent: Double? {
        guard demands(.disk), let diskBytes, diskBytes.total > 0 else { return nil }
        return (Double(diskBytes.used) / Double(diskBytes.total) * 100).rounded()
    }

    private func sampleSlowly(gpu: Bool, disk: Bool) -> Bool {
        guard gpu || disk, !slowSampling else { return false }
        slowSampling = true
        Self.slowSampler.async { [weak self] in
            let usage = gpu ? SystemStatsSampler.gpuUtilization() : nil
            let bytes = disk ? SystemStatsSampler.diskSample() : nil
            DispatchQueue.main.async { [weak self] in
                self?.finishSlowSample(gpu: gpu, usage: usage, disk: bytes)
            }
        }
        return true
    }

    private func finishSlowSample(gpu sampledGPU: Bool, usage: Double?, disk: (used: Int64, total: Int64)?) {
        slowSampling = false
        guard started else { return }
        let previous = data
        if sampledGPU, demands(.gpu) {
            data.gpu = usage.map { ($0 * 100).rounded() }
        }
        if let disk {
            diskBytes = disk
            data.disk = diskPercent
            refreshSystem(memory: data.system.map { ($0.memoryUsed, $0.memoryTotal) } ?? SystemStatsSampler
                .memorySample())
        }
        if data != previous {
            publish()
        }
    }

    func sampleSystem() {
        sampleProviders()
        if demands(.cpu) {
            let now = ProcessInfo.processInfo.systemUptime
            if cpuMeter.isDue(at: now), let usage = cpuMeter.usage(of: SystemStatsSampler.currentCPUTicks(), at: now) {
                data.cpu = (usage * 100).rounded()
            }
        } else {
            data.cpu = nil
            cpuMeter.reset()
        }
        let memory = demands(.memory) || demands(.system) ? SystemStatsSampler.memorySample() : (used: 0, total: 0)
        data.memory = demands(.memory) && memory.total > 0
            ? (Double(memory.used) / Double(memory.total) * 100).rounded() : 0
        refreshSystem(memory: memory)
    }

    private func refreshSystem(memory: (used: UInt64, total: UInt64)) {
        guard demands(.system), let diskBytes else {
            data.system = nil
            return
        }
        var system = data.system ?? ShellSystemData(host: host, displays: NSScreen.screens.map { screen in
            ShellSystemDisplay(
                width: Int(screen.frame.width * screen.backingScaleFactor),
                height: Int(screen.frame.height * screen.backingScaleFactor),
                refresh: screen.maximumFramesPerSecond
            )
        })
        system.memoryUsed = memory.used
        system.memoryTotal = memory.total
        system.pressure = SystemStatsSampler.memoryPressure()
        system.diskUsed = diskBytes.used
        system.diskTotal = diskBytes.total
        system.uptime = SystemStatsSampler.uptime().rounded(.down)
        data.system = system
    }
}
