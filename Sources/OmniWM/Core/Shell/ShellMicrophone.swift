// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AudioToolbox
import CoreAudio
import Foundation

struct ShellMicrophone: Equatable, Sendable {
    var volume: Double?
    var muted: Bool?

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("volume")
        volume.map { writer.number($0) } ?? writer.null()
        writer.key("muted")
        muted.map { writer.bool($0) } ?? writer.null()
    }
}

enum ShellMicrophoneCommand: Equatable, Sendable {
    case set(percent: Double)
    case toggleMute

    init?(words: [String]) {
        switch words {
        case ["mute"]: self = .toggleMute
        case let words where words.count == 2 && words[0] == "set":
            guard let percent = Double(words[1]), percent.isFinite, (0 ... 100).contains(percent) else { return nil }
            self = .set(percent: percent)
        default: return nil
        }
    }
}

@MainActor
struct ShellMicrophoneAccess {
    var defaultDevice: @MainActor () -> AudioObjectID?
    var read: @MainActor (AudioObjectID) -> ShellMicrophone
    var setVolume: @MainActor (AudioObjectID, Double) -> Bool
    var setMuted: @MainActor (AudioObjectID, Bool) -> Bool
    var addListener: @MainActor (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock)
        -> OSStatus
    var removeListener: @MainActor (
        AudioObjectID,
        AudioObjectPropertyAddress,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    static let live = ShellMicrophoneAccess(
        defaultDevice: ShellAudio.defaultInput,
        read: { device in
            let scope = kAudioDevicePropertyScopeInput
            return ShellMicrophone(
                volume: ShellAudio.inputControlWritable(device, address: ShellAudio.volumeAddress(scope: scope))
                    ? ShellAudio.volume(of: device, scope: scope)
                    .flatMap { $0.isFinite && (0 ... 100).contains($0) ? $0 : nil }
                    : nil,
                muted: ShellAudio.inputControlWritable(device, address: ShellAudio.muteAddress(scope: scope))
                    ? ShellAudio.muted(of: device, scope: scope) : nil
            )
        },
        setVolume: { device, percent in
            ShellAudio.writeInput(
                Float32(percent / 100),
                on: device,
                address: ShellAudio.volumeAddress(scope: kAudioDevicePropertyScopeInput)
            )
        },
        setMuted: { device, muted in
            ShellAudio.writeInput(
                UInt32(muted ? 1 : 0),
                on: device,
                address: ShellAudio.muteAddress(scope: kAudioDevicePropertyScopeInput)
            )
        },
        addListener: { device, address, block in
            var address = address
            guard AudioObjectHasProperty(device, &address) else { return kAudioHardwareUnknownPropertyError }
            return AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        },
        removeListener: { device, address, block in
            var address = address
            return AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
    )

    @discardableResult
    func perform(_ command: ShellMicrophoneCommand) -> Bool {
        guard let device = defaultDevice() else { return false }
        let value = read(device)
        switch command {
        case let .set(percent):
            guard percent.isFinite, (0 ... 100).contains(percent), value.volume != nil else { return false }
            return setVolume(device, percent)
        case .toggleMute:
            guard let muted = value.muted else { return false }
            return setMuted(device, !muted)
        }
    }
}

extension ShellAudio {
    @MainActor
    @discardableResult
    static func perform(_ command: ShellMicrophoneCommand) -> Bool {
        ShellMicrophoneAccess.live.perform(command)
    }

    fileprivate static func inputControlWritable(_ device: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var writable: DarwinBoolean = false
        return address.mScope == kAudioDevicePropertyScopeInput && AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &writable) == noErr && writable.boolValue
    }

    fileprivate static func writeInput(
        _ value: some BitwiseCopyable,
        on device: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> Bool {
        guard inputControlWritable(device, address: address) else { return false }
        var address = address
        let status = withUnsafeBytes(of: value) { bytes in
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
        }
        if status != noErr { Log.shell.error("Setting a microphone control failed with status \(status)") }
        return status == noErr
    }
}

@MainActor
final class ShellMicrophoneMonitor {
    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private(set) var value = ShellMicrophone()
    var onChange: ((ShellMicrophone) -> Void)?
    private let access: ShellMicrophoneAccess
    private var listening = false
    private var device: AudioObjectID?
    private var listeners: [Listener] = []

    init(access: ShellMicrophoneAccess = .live) {
        self.access = access
    }

    isolated deinit {
        removeListeners()
    }

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        if listening {
            listen(to: AudioObjectID(kAudioObjectSystemObject), address: ShellAudio.defaultInputAddress)
            refresh()
        } else {
            removeListeners()
            device = nil
            publish(ShellMicrophone())
        }
    }

    @discardableResult
    func perform(_ command: ShellMicrophoneCommand) -> Bool {
        let succeeded = access.perform(command)
        if listening { refresh() }
        return succeeded
    }

    private func refresh() {
        guard listening else { return }
        let current = access.defaultDevice()
        if current != device {
            removeListeners(keepingSystem: true)
            device = current
            if let current {
                listen(to: current, address: ShellAudio.volumeAddress(scope: kAudioDevicePropertyScopeInput))
                listen(to: current, address: ShellAudio.muteAddress(scope: kAudioDevicePropertyScopeInput))
            }
        }
        if let current { publish(access.read(current)) }
        else { publish(ShellMicrophone()) }
    }

    private func publish(_ value: ShellMicrophone) {
        guard value != self.value else { return }
        self.value = value
        onChange?(value)
    }

    private func listen(to object: AudioObjectID, address: AudioObjectPropertyAddress) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if access.addListener(object, address, block) == noErr {
            listeners.append(Listener(object: object, address: address, block: block))
        }
    }

    private func removeListeners(keepingSystem: Bool = false) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for listener in listeners where !keepingSystem || listener.object != system {
            _ = access.removeListener(listener.object, listener.address, listener.block)
        }
        if keepingSystem { listeners.removeAll { $0.object != system } }
        else { listeners.removeAll() }
    }
}
