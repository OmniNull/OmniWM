// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreAudio
import CoreMediaIO
import Foundation

struct ShellPrivacy: Equatable, Sendable, ShellValueWritable {
    var microphone = false
    var camera = false

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("microphone")
        writer.bool(microphone)
        writer.key("camera")
        writer.bool(camera)
    }
}

@MainActor
final class PrivacyMonitor: ShellDeviceSource {
    @MainActor
    struct Hardware {
        var processes: @MainActor () -> [AudioObjectID] = ShellAudio.otherProcesses
        var cameras: @MainActor () -> [CMIOObjectID] = PrivacyMonitor.cameras
        var inputRunning: @MainActor (AudioObjectID) -> Bool = ShellAudio.isRunningInput
        var cameraRunning: @MainActor (CMIOObjectID) -> Bool = PrivacyMonitor.isRunningSomewhere
        var addAudioListener: @MainActor (
            AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock
        ) -> OSStatus = { object, address, block in
            var address = address
            return AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        }

        var removeAudioListener: @MainActor (
            AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock
        ) -> OSStatus = { object, address, block in
            var address = address
            return AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }

        var addVideoListener: @MainActor (
            CMIOObjectID, CMIOObjectPropertyAddress, @escaping CMIOObjectPropertyListenerBlock
        ) -> OSStatus = { object, address, block in
            var address = address
            return CMIOObjectAddPropertyListenerBlock(object, &address, .main, block)
        }

        var removeVideoListener: @MainActor (
            CMIOObjectID, CMIOObjectPropertyAddress, @escaping CMIOObjectPropertyListenerBlock
        ) -> OSStatus = { object, address, block in
            var address = address
            return CMIOObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    private struct AudioListener {
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        var running = false
    }

    private struct VideoListener {
        let address: CMIOObjectPropertyAddress
        let block: CMIOObjectPropertyListenerBlock
        var running = false
    }

    private(set) var value: ShellPrivacy?
    var onChange: ((ShellPrivacy?) -> Void)?
    private let hardware: Hardware
    private var listening = false
    private var generation = 0
    private var audio: [AudioObjectID: AudioListener] = [:]
    private var video: [CMIOObjectID: VideoListener] = [:]

    init(hardware: Hardware = Hardware()) {
        self.hardware = hardware
    }

    var listenerCount: Int {
        audio.count + video.count
    }

    func setListening(_ listening: Bool) {
        guard listening != self.listening else { return }
        self.listening = listening
        generation += 1
        guard listening else {
            removeListeners()
            value = nil
            return
        }
        listen(to: AudioObjectID(kAudioObjectSystemObject), ShellAudio.processesAddress)
        listen(to: CMIOObjectID(kCMIOObjectSystemObject), Self.address(kCMIOHardwarePropertyDevices))
        _ = reconcileAudio()
        _ = reconcileVideo()
        publish()
    }

    private func reconcileAudio() -> Bool {
        let processes = Set(hardware.processes())
        let removed = audio.keys.filter { $0 != kAudioObjectSystemObject && !processes.contains($0) }
        var changed = !removed.isEmpty
        for process in removed {
            if let listener = audio.removeValue(forKey: process) {
                _ = hardware.removeAudioListener(process, listener.address, listener.block)
            }
        }
        for process in processes where audio[process] == nil {
            listen(to: process, ShellAudio.runningInputAddress)
            if audio[process] != nil {
                audio[process]?.running = hardware.inputRunning(process)
                changed = true
            }
        }
        return changed
    }

    private func reconcileVideo() -> Bool {
        let cameras = Set(hardware.cameras())
        let removed = video.keys.filter { $0 != kCMIOObjectSystemObject && !cameras.contains($0) }
        var changed = !removed.isEmpty
        for camera in removed {
            if let listener = video.removeValue(forKey: camera) {
                _ = hardware.removeVideoListener(camera, listener.address, listener.block)
            }
        }
        for camera in cameras where video[camera] == nil {
            listen(to: camera, Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere))
            if video[camera] != nil {
                video[camera]?.running = hardware.cameraRunning(camera)
                changed = true
            }
        }
        return changed
    }

    private func audioChanged(_ object: AudioObjectID, generation: Int) {
        guard listening, generation == self.generation, audio[object] != nil else { return }
        if object == kAudioObjectSystemObject {
            guard reconcileAudio() else { return }
        } else {
            audio[object]?.running = hardware.inputRunning(object)
        }
        publish()
    }

    private func videoChanged(_ object: CMIOObjectID, generation: Int) {
        guard listening, generation == self.generation, video[object] != nil else { return }
        if object == kCMIOObjectSystemObject {
            guard reconcileVideo() else { return }
        } else {
            video[object]?.running = hardware.cameraRunning(object)
        }
        publish()
    }

    private func publish() {
        let next = ShellPrivacy(
            microphone: audio.values.contains(where: { $0.running }),
            camera: video.values.contains(where: { $0.running })
        )
        guard next != value else { return }
        value = next
        onChange?(next)
    }

    private func listen(to object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        let generation = generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard UnsafeBufferPointer(start: addresses, count: Int(count)).contains(where: {
                $0.mSelector == address.mSelector && $0.mScope == address.mScope && $0.mElement == address.mElement
            }) else { return }
            MainActor.assumeIsolated {
                self?.audioChanged(object, generation: generation)
            }
        }
        if hardware.addAudioListener(object, address, block) == noErr {
            audio[object] = AudioListener(address: address, block: block)
        }
    }

    private func listen(to object: CMIOObjectID, _ address: CMIOObjectPropertyAddress) {
        let generation = generation
        let block: CMIOObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard UnsafeBufferPointer(start: addresses, count: Int(count)).contains(where: {
                $0.mSelector == address.mSelector && $0.mScope == address.mScope && $0.mElement == address.mElement
            }) else { return }
            MainActor.assumeIsolated {
                self?.videoChanged(object, generation: generation)
            }
        }
        if hardware.addVideoListener(object, address, block) == noErr {
            video[object] = VideoListener(address: address, block: block)
        }
    }

    private func removeListeners() {
        for (object, listener) in audio {
            _ = hardware.removeAudioListener(object, listener.address, listener.block)
        }
        for (object, listener) in video {
            _ = hardware.removeVideoListener(object, listener.address, listener.block)
        }
        audio.removeAll()
        video.removeAll()
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func cameras() -> [CMIOObjectID] {
        var address = address(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var cameras = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &cameras) == noErr else { return [] }
        return Array(cameras.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func isRunningSomewhere(_ camera: CMIOObjectID) -> Bool {
        var address = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(camera, &address, 0, nil, size, &used, &running) == noErr && running != 0
    }
}
