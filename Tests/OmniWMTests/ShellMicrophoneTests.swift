// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreAudio
@testable import OmniWM
import XCTest

@MainActor
final class ShellMicrophoneTests: XCTestCase {
    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    @MainActor
    private final class Device {
        var input: AudioObjectID? = 42
        var values: [AudioObjectID: ShellMicrophone] = [42: .init(volume: 50, muted: false)]
        var reads: [AudioObjectID] = []
        var volumeWrites: [(AudioObjectID, Double)] = []
        var muteWrites: [(AudioObjectID, Bool)] = []
        var listeners: [Listener] = []
        var removed: [Listener] = []
        var rejectVolumeListener = false

        var access: ShellMicrophoneAccess {
            ShellMicrophoneAccess(
                defaultDevice: { [self] in input },
                read: { [self] object in
                    reads.append(object)
                    return values[object] ?? ShellMicrophone()
                },
                setVolume: { [self] object, percent in
                    volumeWrites.append((object, percent))
                    values[object]?.volume = percent
                    return true
                },
                setMuted: { [self] object, muted in
                    muteWrites.append((object, muted))
                    values[object]?.muted = muted
                    return true
                },
                addListener: { [self] object, address, block in
                    if rejectVolumeListener, address.mSelector == ShellAudio.volumeAddress.mSelector {
                        return kAudioHardwareUnknownPropertyError
                    }
                    listeners.append(Listener(object: object, address: address, block: block))
                    return noErr
                },
                removeListener: { [self] object, address, block in
                    removed.append(Listener(object: object, address: address, block: block))
                    listeners.removeAll {
                        $0.object == object && $0.address.mSelector == address.mSelector
                            && $0.address.mScope == address.mScope && $0.address.mElement == address.mElement
                    }
                    return noErr
                }
            )
        }

        func fire(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws {
            let listener = try XCTUnwrap(listeners.first {
                $0.object == object && $0.address.mSelector == selector
            })
            ShellMicrophoneTests.deliver(listener)
        }
    }

    private static func deliver(_ listener: Listener) {
        var address = listener.address
        withUnsafePointer(to: &address) { listener.block(1, $0) }
    }

    func testCommandsAcceptOnlyFinitePercentagesAndMute() {
        for (words, expected): ([String], ShellMicrophoneCommand?) in [
            (["set", "0"], .set(percent: 0)), (["set", "100"], .set(percent: 100)),
            (["set", "42.5"], .set(percent: 42.5)), (["mute"], .toggleMute),
            (["set", "-1"], nil), (["set", "101"], nil), (["set", "nan"], nil),
            (["set", "inf"], nil), (["set"], nil), (["mute", "on"], nil), (["up"], nil)
        ] {
            XCTAssertEqual(ShellMicrophoneCommand(words: words), expected, words.joined(separator: " "))
        }
    }

    func testListeningIsDemandGatedAndCallbacksPublishOnlyChangedInputValues() throws {
        let device = Device()
        let monitor = ShellMicrophoneMonitor(access: device.access)
        var changes: [ShellMicrophone] = []
        monitor.onChange = { changes.append($0) }
        XCTAssertTrue(device.reads.isEmpty)
        XCTAssertTrue(device.listeners.isEmpty)
        monitor.setListening(true)
        XCTAssertEqual(device.reads, [42])
        XCTAssertEqual(device.listeners.count, 3)
        XCTAssertEqual(monitor.value, .init(volume: 50, muted: false))
        XCTAssertEqual(changes.count, 1)
        monitor.setListening(true)
        XCTAssertEqual(device.listeners.count, 3)
        try device.fire(42, selector: ShellAudio.volumeAddress.mSelector)
        XCTAssertEqual(changes.count, 1)
        device.values[42] = .init(volume: 75, muted: true)
        try device.fire(42, selector: ShellAudio.muteAddress.mSelector)
        XCTAssertEqual(monitor.value, .init(volume: 75, muted: true))
        XCTAssertEqual(changes.count, 2)
        monitor.setListening(false)
    }

    func testDefaultInputSwitchRebindsOnlyItsOwnDeviceListeners() throws {
        let device = Device()
        let monitor = ShellMicrophoneMonitor(access: device.access)
        monitor.setListening(true)
        let inputListeners = device.listeners.filter { $0.object == 42 }
        XCTAssertEqual(
            inputListeners.map(\.address.mScope),
            [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeInput]
        )
        device.input = 77
        device.values[77] = .init(volume: 25, muted: true)
        try device.fire(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice)
        XCTAssertEqual(device.removed.map(\.object), [42, 42])
        XCTAssertEqual(device.listeners.map(\.object), [AudioObjectID(kAudioObjectSystemObject), 77, 77])
        XCTAssertEqual(monitor.value, .init(volume: 25, muted: true))
        XCTAssertEqual(ShellAudio.volumeAddress.mScope, kAudioDevicePropertyScopeOutput)
        XCTAssertEqual(ShellAudio.muteAddress.mScope, kAudioDevicePropertyScopeOutput)
        XCTAssertEqual(ShellAudio.defaultOutputAddress.mSelector, kAudioHardwarePropertyDefaultOutputDevice)
        monitor.setListening(false)
    }

    func testStoppingRemovesAllListenersAndIgnoresQueuedCallbacks() throws {
        let device = Device()
        let monitor = ShellMicrophoneMonitor(access: device.access)
        monitor.setListening(true)
        let callback = try XCTUnwrap(device.listeners.first)
        monitor.setListening(false)
        let readCount = device.reads.count
        XCTAssertTrue(device.listeners.isEmpty)
        XCTAssertEqual(device.removed.count, 3)
        XCTAssertEqual(monitor.value, ShellMicrophone())
        Self.deliver(callback)
        XCTAssertEqual(device.reads.count, readCount)
        XCTAssertTrue(device.listeners.isEmpty)
        monitor.setListening(false)
        XCTAssertEqual(device.removed.count, 3)
    }

    func testReleasingAListeningMonitorUnregistersItsOwnedBlocks() throws {
        let device = Device()
        var monitor: ShellMicrophoneMonitor? = ShellMicrophoneMonitor(access: device.access)
        let released = { [weak monitor] in monitor == nil }
        monitor?.setListening(true)
        let callback = try XCTUnwrap(device.listeners.first)
        XCTAssertEqual(device.listeners.count, 3)
        monitor = nil
        XCTAssertTrue(released())
        XCTAssertTrue(device.listeners.isEmpty)
        XCTAssertEqual(device.removed.count, 3)
        Self.deliver(callback)
        XCTAssertTrue(device.listeners.isEmpty)
    }

    func testCommandsWriteOnlyTheDefaultInputAndPreserveIndependentMuteAndLevel() throws {
        let device = Device()
        let monitor = ShellMicrophoneMonitor(access: device.access)
        monitor.setListening(true)
        XCTAssertTrue(monitor.perform(.set(percent: 80)))
        XCTAssertEqual(device.volumeWrites.map { $0.0 }, [42])
        XCTAssertEqual(device.volumeWrites.map { $0.1 }, [80])
        XCTAssertTrue(device.muteWrites.isEmpty)
        XCTAssertEqual(monitor.value, .init(volume: 80, muted: false))
        device.input = 77
        device.values[77] = .init(volume: 25, muted: false)
        XCTAssertTrue(monitor.perform(.toggleMute))
        XCTAssertEqual(device.muteWrites.map { $0.0 }, [77])
        XCTAssertEqual(device.muteWrites.map { $0.1 }, [true])
        XCTAssertEqual(monitor.value, .init(volume: 25, muted: true))
        XCTAssertFalse(monitor.perform(.set(percent: .nan)))
        XCTAssertFalse(monitor.perform(.set(percent: 101)))
        XCTAssertEqual(device.volumeWrites.count, 1)
        monitor.setListening(false)
    }

    func testUnsupportedControlsAndMissingInputRemainUnavailableWithoutWrites() throws {
        let device = Device()
        device.values[42] = ShellMicrophone()
        device.rejectVolumeListener = true
        let monitor = ShellMicrophoneMonitor(access: device.access)
        monitor.setListening(true)
        XCTAssertEqual(monitor.value, ShellMicrophone())
        XCTAssertFalse(monitor.perform(.set(percent: 50)))
        XCTAssertFalse(monitor.perform(.toggleMute))
        XCTAssertTrue(device.volumeWrites.isEmpty)
        XCTAssertTrue(device.muteWrites.isEmpty)
        device.input = nil
        try device.fire(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice)
        XCTAssertEqual(monitor.value, ShellMicrophone())
        XCTAssertEqual(device.listeners.count, 1)
        XCTAssertFalse(monitor.perform(.toggleMute))
        monitor.setListening(false)
    }

    func testValueEncodingPreservesUnavailableFields() throws {
        var writer = ShellValueWriter()
        ShellMicrophone(volume: 42.5, muted: nil).write(into: &writer)
        XCTAssertEqual(try ShellServiceValue.decode(writer.bytes), .object([
            "volume": .number(42.5), "muted": .null
        ]))
        writer.reset()
        ShellMicrophone(volume: nil, muted: true).write(into: &writer)
        XCTAssertEqual(try ShellServiceValue.decode(writer.bytes), .object([
            "volume": .null, "muted": .bool(true)
        ]))
    }
}
