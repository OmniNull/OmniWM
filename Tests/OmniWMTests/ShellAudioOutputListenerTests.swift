// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreAudio
@testable import OmniWM
import XCTest

@MainActor
final class ShellAudioOutputListenerTests: XCTestCase {
    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    @MainActor
    private final class Hardware {
        var output: AudioObjectID? = 42
        var controls: [AudioObjectID: (volume: Double, muted: Bool)] = [42: (50, false)]
        var devices = [ShellAudioOutput(id: 42, name: "Speakers", transport: "builtin", isDefault: true)]
        var listeners: [Listener] = []
        var removed: [Listener] = []

        var access: ShellAudioOutputAccess {
            ShellAudioOutputAccess(
                defaultDevice: { [self] in output },
                volume: { [self] in controls[$0]?.volume },
                muted: { [self] in controls[$0]?.muted },
                outputs: { [self] _ in devices },
                addListener: { [self] object, address, block in
                    if object != ShellAudioOutputListenerTests.system, controls[object] == nil {
                        return kAudioHardwareUnknownPropertyError
                    }
                    listeners.append(Listener(object: object, address: address, block: block))
                    return noErr
                },
                removeListener: { [self] object, address, block in
                    removed.append(Listener(object: object, address: address, block: block))
                    listeners.removeAll { $0.object == object && $0.address.mSelector == address.mSelector }
                    return noErr
                }
            )
        }

        func fire(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws {
            let listener = try XCTUnwrap(listeners.first {
                $0.object == object && $0.address.mSelector == selector
            })
            ShellAudioOutputListenerTests.deliver(listener)
        }
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let demand = ShellDataKey.volume.bit | ShellDataKey.muted.bit | ShellDataKey.outputs.bit

    private static func deliver(_ listener: Listener) {
        var address = listener.address
        withUnsafePointer(to: &address) { listener.block(1, $0) }
    }

    private static func listeningFeed(_ hardware: Hardware) -> ShellDataFeed {
        let feed = ShellDataFeed(audioOutput: hardware.access, deliver: { _ in })
        feed.start()
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        return feed
    }

    func testOutputCallbacksKeepListenersWhenTheDefaultOutputHasNoVolumeControls() throws {
        let hardware = Hardware()
        hardware.output = 52
        hardware.devices = [ShellAudioOutput(id: 52, name: "Multi-Output", transport: "aggregate", isDefault: true)]
        let feed = Self.listeningFeed(hardware)
        defer { feed.stop() }
        XCTAssertEqual(hardware.listeners.map(\.object), [Self.system, Self.system])
        XCTAssertNil(feed.current.volume)
        hardware.devices.append(ShellAudioOutput(id: 61, name: "Display", transport: "hdmi", isDefault: false))
        try hardware.fire(Self.system, selector: kAudioHardwarePropertyDevices)
        try hardware.fire(Self.system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        XCTAssertTrue(hardware.removed.isEmpty)
        XCTAssertEqual(hardware.listeners.map(\.object), [Self.system, Self.system])
        XCTAssertEqual(feed.current.outputs?.map(\.id), [52, 61])
        XCTAssertNil(feed.current.volume)
    }

    func testDefaultOutputSwitchRebindsOnlyItsOwnDeviceListeners() throws {
        let hardware = Hardware()
        let feed = Self.listeningFeed(hardware)
        defer { feed.stop() }
        XCTAssertEqual(hardware.listeners.map(\.object), [Self.system, Self.system, 42, 42])
        XCTAssertEqual(feed.current.volume, 50)
        hardware.output = 77
        hardware.controls[77] = (25, true)
        try hardware.fire(Self.system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        XCTAssertEqual(hardware.removed.map(\.object), [42, 42])
        XCTAssertEqual(hardware.listeners.map(\.object), [Self.system, Self.system, 77, 77])
        XCTAssertEqual(feed.current.volume, 25)
        XCTAssertEqual(feed.current.muted, true)
        hardware.output = nil
        try hardware.fire(Self.system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        XCTAssertEqual(hardware.removed.map(\.object), [42, 42, 77, 77])
        XCTAssertEqual(hardware.listeners.map(\.object), [Self.system, Self.system])
        XCTAssertNil(feed.current.volume)
        XCTAssertNil(feed.current.muted)
    }

    func testSwitchingFromAnOutputWithoutControlsListensToTheNewOutputsControls() throws {
        let hardware = Hardware()
        hardware.output = 52
        let feed = Self.listeningFeed(hardware)
        defer { feed.stop() }
        XCTAssertEqual(hardware.listeners.map(\.object), [Self.system, Self.system])
        XCTAssertNil(feed.current.volume)
        hardware.output = 42
        try hardware.fire(Self.system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        XCTAssertTrue(hardware.removed.isEmpty)
        XCTAssertEqual(hardware.listeners.map(\.object), [Self.system, Self.system, 42, 42])
        XCTAssertEqual(feed.current.volume, 50)
    }

    func testCallbacksDeliveredAfterAudioDemandEndsRegisterNoListeners() throws {
        let hardware = Hardware()
        let feed = Self.listeningFeed(hardware)
        defer { feed.stop() }
        let queued = try XCTUnwrap(hardware.listeners.first)
        feed.setDemand(0, cadence: .init())
        XCTAssertTrue(hardware.listeners.isEmpty)
        Self.deliver(queued)
        XCTAssertTrue(hardware.listeners.isEmpty)
        XCTAssertNil(feed.current.volume)
    }
}
