// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import AudioToolbox
import CoreAudio

enum ShellVolumeCommand: Equatable, Sendable {
    static let step = 100.0 / 16

    case change(percent: Double)
    case toggleMute
    case set(percent: Double)
    case output(AudioObjectID)
    case app(String, AppVolumeCommand)
    case permission

    init?(words: [String]) {
        switch words {
        case ["up"]: self = .change(percent: Self.step)
        case ["down"]: self = .change(percent: -Self.step)
        case ["mute"]: self = .toggleMute
        case ["permission"]: self = .permission
        case let words where words.count >= 3 && words[0] == "app":
            guard let command = AppVolumeCommand(words: Array(words.dropFirst(2))) else { return nil }
            self = .app(words[1], command)
        case let words where words.count == 2 && ["up", "down"].contains(words[0]):
            guard let percent = Double(words[1]), percent.isFinite, percent > 0 else { return nil }
            self = .change(percent: words[0] == "up" ? percent : -percent)
        case let words where words.count == 2 && words[0] == "set":
            guard let percent = Double(words[1]), percent.isFinite else { return nil }
            self = .set(percent: percent)
        case let words where words.count == 2 && words[0] == "output":
            guard let device = AudioObjectID(words[1]) else { return nil }
            self = .output(device)
        default: return nil
        }
    }
}

struct ShellAudioOutput: Equatable, Sendable {
    let id: AudioObjectID
    let name: String
    let transport: String
    let isDefault: Bool

    func write(into writer: inout ShellValueWriter) {
        writer.map(4)
        writer.key("id")
        writer.string(String(id))
        writer.key("name")
        writer.string(name)
        writer.key("transport")
        writer.string(transport)
        writer.key("default")
        writer.bool(isDefault)
    }
}

enum ShellAudio {
    static let privateDeviceUIDPrefix = "com.barut.OmniWM.app-volume."

    static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutput() -> AudioObjectID? {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static var processesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var runningInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func devices() -> [AudioObjectID] {
        objects(devicesAddress)
    }

    static func otherProcesses() -> [AudioObjectID] {
        objects(processesAddress).filter { pid(of: $0) != ProcessInfo.processInfo.processIdentifier }
    }

    static func pid(of process: AudioObjectID) -> pid_t? {
        value(kAudioProcessPropertyPID, of: process).map { pid_t(bitPattern: $0) }
    }

    static func isRunningInput(_ process: AudioObjectID) -> Bool {
        value(kAudioProcessPropertyIsRunningInput, of: process) ?? 0 != 0
    }

    static func isOwn(uid: String?) -> Bool {
        uid?.hasPrefix(privateDeviceUIDPrefix) == true
    }

    private static func objects(_ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func outputs(default current: AudioObjectID?) -> [ShellAudioOutput] {
        devices().compactMap { device in
            guard canBeDefaultOutput(device), !isOwn(uid: uid(of: device)),
                  let name = string(kAudioObjectPropertyName, of: device)
            else {
                return nil
            }
            return ShellAudioOutput(
                id: device,
                name: name,
                transport: transport(code: value(kAudioDevicePropertyTransportType, of: device) ?? 0),
                isDefault: device == current
            )
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func transport(code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: "builtin"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
        case kAudioDeviceTransportTypeHDMI: "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: "displayport"
        case kAudioDeviceTransportTypeAirPlay: "airplay"
        case kAudioDeviceTransportTypeThunderbolt: "thunderbolt"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: "aggregate"
        default: "other"
        }
    }

    private static func canBeDefaultOutput(_ device: AudioObjectID) -> Bool {
        hasStreams(device, scope: kAudioDevicePropertyScopeOutput)
            && value(kAudioDevicePropertyDeviceCanBeDefaultDevice, of: device, scope: kAudioDevicePropertyScopeOutput)
            == 1
    }

    private static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func value(
        _ selector: AudioObjectPropertySelector,
        of device: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(kAudioDevicePropertyDeviceUID, of: device)
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value = value?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
        return value
    }

    static func volume(of device: AudioObjectID) -> Double? {
        scalarVolume(of: device).map { ($0 * 100).rounded() }
    }

    private static func scalarVolume(of device: AudioObjectID) -> Double? {
        var address = volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return Double(value)
    }

    static func muted(of device: AudioObjectID) -> Bool? {
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return value != 0
    }

    @MainActor
    static func perform(_ command: ShellVolumeCommand, appVolumes: AppVolumeMixer?) {
        switch command {
        case let .output(device):
            setDefaultOutput(device)
        case let .app(bundle, command):
            appVolumes?.perform(command, on: bundle)
        case .permission:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                NSWorkspace.shared.open(url)
            }
        case let .change(percent):
            guard let device = defaultOutput() else { return }
            setLevel((scalarVolume(of: device) ?? 0) + percent / 100, on: device)
        case .toggleMute:
            guard let device = defaultOutput() else { return }
            setMuted(!(muted(of: device) ?? false), on: device)
        case let .set(percent):
            guard let device = defaultOutput() else { return }
            setLevel(percent / 100, on: device)
        }
    }

    private static func setLevel(_ value: Double, on device: AudioObjectID) {
        let level = min(max(value, 0), 1)
        setVolume(level, on: device)
        setMuted(level == 0, on: device)
    }

    private static func setDefaultOutput(_ device: AudioObjectID) {
        guard outputs(default: nil).contains(where: { $0.id == device }) else {
            Log.shell.error("Audio output \(device) is not an output device")
            return
        }
        var address = defaultOutputAddress
        var device = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &device
        )
        if status != noErr {
            Log.shell.error("Switching the audio output failed with status \(status)")
        }
    }

    private static func setVolume(_ value: Double, on device: AudioObjectID) {
        var address = volumeAddress
        var volume = Float32(value)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if status != noErr {
            Log.shell.error("Setting the output volume failed with status \(status)")
        }
    }

    private static func setMuted(_ muted: Bool, on device: AudioObjectID) {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        guard AudioObjectHasProperty(device, &address) else { return }
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            Log.shell.error("Setting output mute failed with status \(status)")
        }
    }
}
