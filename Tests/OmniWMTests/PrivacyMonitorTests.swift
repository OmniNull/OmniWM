// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreAudio
import CoreMediaIO
@testable import OmniWM
import XCTest

@MainActor
final class PrivacyMonitorTests: XCTestCase {
    private struct AudioSubscription {
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct VideoSubscription {
        let address: CMIOObjectPropertyAddress
        let block: CMIOObjectPropertyListenerBlock
    }

    @MainActor
    private final class Hardware {
        var processes: [AudioObjectID] = [10, 20]
        var cameras: [CMIOObjectID] = [30]
        var inputs: [AudioObjectID: Bool] = [:]
        var runningCameras: [CMIOObjectID: Bool] = [:]
        var processReads = 0
        var deviceReads = 0
        var inputReads: [AudioObjectID] = []
        var cameraReads: [CMIOObjectID] = []
        var audioAdds: [AudioObjectID] = []
        var videoAdds: [CMIOObjectID] = []
        var audioRemoves: [AudioObjectID] = []
        var videoRemoves: [CMIOObjectID] = []
        var audio: [AudioObjectID: AudioSubscription] = [:]
        var video: [CMIOObjectID: VideoSubscription] = [:]
        var notifyOnRegistration = false
        var pending: [() -> Void] = []

        var operations: PrivacyMonitor.Hardware {
            PrivacyMonitor.Hardware(
                processes: {
                    self.processReads += 1
                    return self.processes
                },
                cameras: {
                    self.deviceReads += 1
                    return self.cameras
                },
                inputRunning: { object in
                    self.inputReads.append(object)
                    return self.inputs[object] ?? false
                },
                cameraRunning: { object in
                    self.cameraReads.append(object)
                    return self.runningCameras[object] ?? false
                },
                addAudioListener: { object, address, block in
                    self.audioAdds.append(object)
                    self.audio[object] = AudioSubscription(address: address, block: block)
                    if self.notifyOnRegistration, let topology = self.audio[AudioObjectID(kAudioObjectSystemObject)] {
                        self.pending.append { Self.send(topology.block, [ShellAudio.processesAddress]) }
                    }
                    return noErr
                },
                removeAudioListener: { object, _, _ in
                    self.audioRemoves.append(object)
                    self.audio[object] = nil
                    return noErr
                },
                addVideoListener: { object, address, block in
                    self.videoAdds.append(object)
                    self.video[object] = VideoSubscription(address: address, block: block)
                    if self.notifyOnRegistration, let topology = self.video[CMIOObjectID(kCMIOObjectSystemObject)] {
                        self.pending.append { Self.send(
                            topology.block,
                            [Self.videoAddress(kCMIOHardwarePropertyDevices)]
                        ) }
                    }
                    return noErr
                },
                removeVideoListener: { object, _, _ in
                    self.videoRemoves.append(object)
                    self.video[object] = nil
                    return noErr
                }
            )
        }

        func audioChanged(_ object: AudioObjectID, _ addresses: [AudioObjectPropertyAddress]) throws {
            Self.send(try XCTUnwrap(audio[object]).block, addresses)
        }

        func videoChanged(_ object: CMIOObjectID, _ addresses: [CMIOObjectPropertyAddress]) throws {
            Self.send(try XCTUnwrap(video[object]).block, addresses)
        }

        func drainRegistrationCallbacks() {
            for _ in 0 ..< 32 {
                guard !pending.isEmpty else { return }
                pending.removeFirst()()
            }
            XCTAssertTrue(pending.isEmpty)
        }

        static func send(_ block: AudioObjectPropertyListenerBlock, _ addresses: [AudioObjectPropertyAddress]) {
            addresses.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    block(UInt32(buffer.count), base)
                }
            }
        }

        static func send(_ block: CMIOObjectPropertyListenerBlock, _ addresses: [CMIOObjectPropertyAddress]) {
            addresses.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    block(UInt32(buffer.count), base)
                }
            }
        }

        static func videoAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
            CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(selector),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
        }
    }

    func testRegistrationCallbacksDrainWithoutRebuildingListenersOrRereadingActivity() {
        let hardware = Hardware()
        hardware.notifyOnRegistration = true
        let monitor = PrivacyMonitor(hardware: hardware.operations)
        defer { monitor.setListening(false) }

        monitor.setListening(true)
        hardware.drainRegistrationCallbacks()

        XCTAssertEqual(hardware.audioAdds.count, 3)
        XCTAssertEqual(hardware.videoAdds.count, 2)
        XCTAssertTrue(hardware.audioRemoves.isEmpty)
        XCTAssertTrue(hardware.videoRemoves.isEmpty)
        XCTAssertEqual(Set(hardware.inputReads), [10, 20])
        XCTAssertEqual(hardware.inputReads.count, 2)
        XCTAssertEqual(hardware.cameraReads, [30])
        XCTAssertEqual(monitor.listenerCount, 5)
        XCTAssertEqual(monitor.value, ShellPrivacy())
    }

    func testUnchangedTopologyOnlyEnumeratesItsOwnDomain() throws {
        let hardware = Hardware()
        let monitor = PrivacyMonitor(hardware: hardware.operations)
        defer { monitor.setListening(false) }
        monitor.setListening(true)

        for _ in 0 ..< 10 {
            try hardware.audioChanged(AudioObjectID(kAudioObjectSystemObject), [ShellAudio.processesAddress])
        }

        XCTAssertEqual(hardware.processReads, 11)
        XCTAssertEqual(hardware.deviceReads, 1)
        for _ in 0 ..< 10 {
            try hardware.videoChanged(
                CMIOObjectID(kCMIOObjectSystemObject),
                [Hardware.videoAddress(kCMIOHardwarePropertyDevices)]
            )
        }

        XCTAssertEqual(hardware.processReads, 11)
        XCTAssertEqual(hardware.deviceReads, 11)
        XCTAssertEqual(hardware.audioAdds.count, 3)
        XCTAssertEqual(hardware.videoAdds.count, 2)
        XCTAssertTrue(hardware.audioRemoves.isEmpty)
        XCTAssertTrue(hardware.videoRemoves.isEmpty)
        XCTAssertEqual(hardware.inputReads.count, 2)
        XCTAssertEqual(hardware.cameraReads, [30])
    }

    func testTopologyChangesOnlyReconcileChangedObjectsAndClearTheLastActiveObject() throws {
        let hardware = Hardware()
        hardware.inputs[10] = true
        hardware.runningCameras[30] = true
        let monitor = PrivacyMonitor(hardware: hardware.operations)
        defer { monitor.setListening(false) }
        monitor.setListening(true)
        XCTAssertEqual(monitor.value, ShellPrivacy(microphone: true, camera: true))

        hardware.processes = [20, 40]
        try hardware.audioChanged(AudioObjectID(kAudioObjectSystemObject), [ShellAudio.processesAddress])

        XCTAssertEqual(hardware.audioRemoves, [10])
        XCTAssertEqual(hardware.audioAdds.count, 4)
        XCTAssertEqual(hardware.audioAdds.last, 40)
        XCTAssertEqual(hardware.inputReads.count, 3)
        XCTAssertEqual(hardware.inputReads.last, 40)
        XCTAssertEqual(hardware.deviceReads, 1)
        XCTAssertEqual(hardware.videoAdds.count, 2)
        XCTAssertTrue(hardware.videoRemoves.isEmpty)
        XCTAssertEqual(hardware.cameraReads, [30])
        XCTAssertEqual(monitor.value, ShellPrivacy(microphone: false, camera: true))

        hardware.cameras = []
        try hardware.videoChanged(
            CMIOObjectID(kCMIOObjectSystemObject),
            [Hardware.videoAddress(kCMIOHardwarePropertyDevices)]
        )

        XCTAssertEqual(hardware.videoRemoves, [30])
        XCTAssertEqual(hardware.processReads, 2)
        XCTAssertEqual(hardware.inputReads.count, 3)
        XCTAssertEqual(monitor.value, ShellPrivacy())
    }

    func testActivityCallbacksFilterAddressesAndReadOnlyTheChangedObject() throws {
        let hardware = Hardware()
        let monitor = PrivacyMonitor(hardware: hardware.operations)
        defer { monitor.setListening(false) }
        var changes: [ShellPrivacy?] = []
        monitor.onChange = { changes.append($0) }
        monitor.setListening(true)

        var wrongElement = ShellAudio.runningInputAddress
        wrongElement.mElement += 1
        var wrongScope = ShellAudio.runningInputAddress
        wrongScope.mScope = kAudioDevicePropertyScopeOutput
        try hardware.audioChanged(10, [wrongElement, wrongScope])
        try hardware.audioChanged(AudioObjectID(kAudioObjectSystemObject), [ShellAudio.devicesAddress])
        try hardware.videoChanged(30, [Hardware.videoAddress(kCMIOHardwarePropertyDevices)])
        XCTAssertEqual(hardware.inputReads.count, 2)
        XCTAssertEqual(hardware.cameraReads.count, 1)
        XCTAssertEqual(hardware.processReads, 1)

        hardware.inputs[10] = true
        try hardware.audioChanged(10, [ShellAudio.devicesAddress, ShellAudio.runningInputAddress])
        XCTAssertEqual(hardware.inputReads.count, 3)
        XCTAssertEqual(hardware.inputReads.last, 10)
        XCTAssertEqual(monitor.value, ShellPrivacy(microphone: true, camera: false))

        hardware.inputs[20] = true
        let changeCount = changes.count
        try hardware.audioChanged(20, [ShellAudio.runningInputAddress])
        XCTAssertEqual(changes.count, changeCount)
        hardware.inputs[10] = false
        try hardware.audioChanged(10, [ShellAudio.runningInputAddress])
        XCTAssertEqual(monitor.value?.microphone, true)
        hardware.inputs[20] = false
        try hardware.audioChanged(20, [ShellAudio.runningInputAddress])
        XCTAssertEqual(monitor.value?.microphone, false)

        hardware.runningCameras[30] = true
        try hardware.videoChanged(30, [
            Hardware.videoAddress(kCMIOHardwarePropertyDevices),
            Hardware.videoAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        ])
        XCTAssertEqual(hardware.cameraReads, [30, 30])
        XCTAssertEqual(hardware.processReads, 1)
        XCTAssertEqual(hardware.deviceReads, 1)
        XCTAssertEqual(monitor.value, ShellPrivacy(microphone: false, camera: true))
    }

    func testRemovedAndPreviousLifetimeCallbacksCannotReadOrPublish() throws {
        let hardware = Hardware()
        let monitor = PrivacyMonitor(hardware: hardware.operations)
        defer { monitor.setListening(false) }
        monitor.setListening(true)
        let oldAudio = try XCTUnwrap(hardware.audio[10])
        let oldVideo = try XCTUnwrap(hardware.video[30])
        let oldAudioTopology = try XCTUnwrap(hardware.audio[AudioObjectID(kAudioObjectSystemObject)])
        let oldVideoTopology = try XCTUnwrap(hardware.video[CMIOObjectID(kCMIOObjectSystemObject)])
        hardware.processes = [20]
        hardware.cameras = []
        try hardware.audioChanged(AudioObjectID(kAudioObjectSystemObject), [ShellAudio.processesAddress])
        try hardware.videoChanged(
            CMIOObjectID(kCMIOObjectSystemObject),
            [Hardware.videoAddress(kCMIOHardwarePropertyDevices)]
        )
        Hardware.send(oldAudio.block, [oldAudio.address])
        Hardware.send(oldVideo.block, [oldVideo.address])
        XCTAssertEqual(hardware.inputReads.count, 2)
        XCTAssertEqual(hardware.cameraReads.count, 1)
        XCTAssertEqual(monitor.value, ShellPrivacy())

        monitor.setListening(false)
        XCTAssertEqual(monitor.listenerCount, 0)
        XCTAssertTrue(hardware.audio.isEmpty)
        XCTAssertTrue(hardware.video.isEmpty)
        XCTAssertNil(monitor.value)
        hardware.processes = [10]
        hardware.cameras = [30]
        monitor.setListening(true)
        let processReads = hardware.processReads
        let deviceReads = hardware.deviceReads
        let inputReads = hardware.inputReads.count
        let cameraReads = hardware.cameraReads.count
        var changes: [ShellPrivacy?] = []
        monitor.onChange = { changes.append($0) }
        hardware.inputs[10] = true
        hardware.runningCameras[30] = true

        Hardware.send(oldAudioTopology.block, [oldAudioTopology.address])
        Hardware.send(oldVideoTopology.block, [oldVideoTopology.address])
        Hardware.send(oldAudio.block, [oldAudio.address])
        Hardware.send(oldVideo.block, [oldVideo.address])

        XCTAssertEqual(hardware.processReads, processReads)
        XCTAssertEqual(hardware.deviceReads, deviceReads)
        XCTAssertEqual(hardware.inputReads.count, inputReads)
        XCTAssertEqual(hardware.cameraReads.count, cameraReads)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(monitor.value, ShellPrivacy())
    }
}
