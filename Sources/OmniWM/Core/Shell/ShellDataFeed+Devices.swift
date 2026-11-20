// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreAudio
import IOKit.ps

struct ShellPower: Equatable, Sendable {
    var source = "ac"
    var remaining: Double?
    var full: Double?
    var charged = false
    var lowPower = false
    var cycles: Double?
    var health: Double?
    var temperature: Double?
    var watts: Double?
    var adapter: Double?

    func write(into writer: inout ShellValueWriter) {
        let details = [
            ("cycles", cycles), ("health", health), ("temperature", temperature), ("watts", watts),
            ("adapter", adapter)
        ]
        writer.map(5 + details.count)
        for (key, value) in details {
            writer.key(key)
            value.map { writer.number($0) } ?? writer.null()
        }
        writer.key("source")
        writer.string(source)
        writer.key("remaining")
        remaining.map { writer.number($0) } ?? writer.null()
        writer.key("full")
        full.map { writer.number($0) } ?? writer.null()
        writer.key("charged")
        writer.bool(charged)
        writer.key("lowPower")
        writer.bool(lowPower)
    }

    static func minutes(_ value: Any?) -> Double? {
        (value as? Int).flatMap { $0 >= 0 ? Double($0) : nil }
    }

    mutating func describe(_ battery: [String: Any]) {
        let number = { (key: String) in (battery[key] as? NSNumber)?.doubleValue }
        cycles = number("CycleCount")
        if let raw = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity"),
           let design = number("DesignCapacity"), design > 0
        {
            health = (raw / design * 100).rounded()
        }
        temperature = number("Temperature").map { ($0 / 100 * 10).rounded() / 10 }
        if let volts = number("Voltage"), let amps = number("InstantAmperage") ?? number("Amperage") {
            watts = (volts * amps / 1_000_000 * 10).rounded() / 10
        }
        adapter = ((battery["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber)?.doubleValue
    }

    static func batteryRegistry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}

@MainActor
struct ShellAudioOutputAccess {
    var defaultDevice: @MainActor () -> AudioObjectID?
    var volume: @MainActor (AudioObjectID) -> Double?
    var muted: @MainActor (AudioObjectID) -> Bool?
    var outputs: @MainActor (AudioObjectID?) -> [ShellAudioOutput]
    var addListener: @MainActor (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock)
        -> OSStatus
    var removeListener: @MainActor (
        AudioObjectID,
        AudioObjectPropertyAddress,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

extension ShellDataFeed {
    func sampleBattery() {
        data.battery = nil
        data.charging = false
        data.power = nil
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return
        }
        if demands(.power) {
            let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            data.power = ShellPower(
                source: providing == kIOPMBatteryPowerKey ? "battery" : providing == kIOPMUPSPowerKey ? "ups" : "ac",
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            else {
                continue
            }
            data.battery = (Double(current) / Double(maximum) * 100).rounded()
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            data.charging = charging
            data.power?.remaining = ShellPower.minutes(description[kIOPSTimeToEmptyKey])
            data.power?.full = charging ? ShellPower.minutes(description[kIOPSTimeToFullChargeKey]) : nil
            data.power?.charged = description[kIOPSIsChargedKey] as? Bool ?? false
            if data.power != nil, let registry = ShellPower.batteryRegistry() {
                data.power?.describe(registry)
            }
            return
        }
    }

    func updateAudio() {
        let wanted = !paused && (demands(.volume) || demands(.muted) || demands(.outputs))
        if wanted == audioListeners.isEmpty {
            if wanted {
                listenToAudio()
            } else {
                removeAudioListeners()
                data.volume = nil
                data.muted = nil
            }
        }
        if (data.outputs != nil) != (wanted && demands(.outputs)) {
            sampleOutputs()
        }
    }

    private func listenToAudio() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listen(to: system, ShellAudio.defaultOutputAddress, outputs: true)
        listen(to: system, ShellAudio.devicesAddress, outputs: true)
        listenToOutputDevice(defaultAudioOutput())
        sampleAudio()
        sampleOutputs()
    }

    private func listenToOutputDevice(_ device: AudioObjectID?) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for listener in audioListeners where listener.object != system {
            removeAudioListener(listener)
        }
        audioListeners.removeAll { $0.object != system }
        listenedOutputDevice = device
        if let device {
            listen(to: device, ShellAudio.volumeAddress)
            listen(to: device, ShellAudio.muteAddress)
        }
    }

    private func listen(to object: AudioObjectID, _ address: AudioObjectPropertyAddress, outputs: Bool = false) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.audioChanged(outputs: outputs)
            }
        }
        if let audioOutput {
            if audioOutput.addListener(object, address, block) == noErr {
                audioListeners.append(AudioPropertyListener(object: object, address: address, block: block))
            }
        } else if let listener = AudioPropertyListener
            .listen(to: object, address: address, queue: .main, block: block)
        {
            audioListeners.append(listener)
        }
    }

    private func removeAudioListener(_ listener: borrowing AudioPropertyListener) {
        if let block = listener.block, let audioOutput {
            let status = audioOutput.removeListener(listener.object, listener.address, block)
            if status != noErr { Log.shell.error("Removing an audio listener failed with status \(status)") }
        } else {
            listener.remove(on: .main)
        }
    }

    func removeAudioListeners() {
        for listener in audioListeners {
            removeAudioListener(listener)
        }
        audioListeners.removeAll()
        listenedOutputDevice = nil
    }

    private func audioChanged(outputs: Bool) {
        guard !audioListeners.isEmpty else { return }
        let previous = (data.volume, data.muted, data.outputs)
        let device = defaultAudioOutput()
        let switched = device != listenedOutputDevice
        if switched {
            listenToOutputDevice(device)
        }
        sampleAudio()
        if outputs || switched {
            sampleOutputs()
        }
        if previous != (data.volume, data.muted, data.outputs) {
            publish()
        }
    }

    private func sampleAudio() {
        if let audioOutput {
            let device = audioOutput.defaultDevice()
            data.volume = device.flatMap { audioOutput.volume($0) }
            data.muted = device.flatMap { audioOutput.muted($0) }
        } else {
            let device = ShellAudio.defaultOutput()
            data.volume = device.flatMap(ShellAudio.volume(of:))
            data.muted = device.flatMap(ShellAudio.muted(of:))
        }
    }

    private func defaultAudioOutput() -> AudioObjectID? {
        if let audioOutput { return audioOutput.defaultDevice() }
        return ShellAudio.defaultOutput()
    }

    private func sampleOutputs() {
        guard !paused, demands(.outputs) else {
            data.outputs = nil
            return
        }
        if let audioOutput {
            data.outputs = audioOutput.outputs(audioOutput.defaultDevice())
        } else {
            data.outputs = ShellAudio.outputs(default: ShellAudio.defaultOutput())
        }
    }
}
