// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import OmniWMScriptHost
import XCTest

extension ShellWidgetPackage {
    fileprivate func systemControlOutput(_ key: ShellBarKey) -> (width: Float, demand: UInt64)? {
        guard let instance = script?.instances[key] else { return nil }
        var count = 0
        guard let bytes = omni_instance_output(instance, OMNI_VIEW_BAR, &count),
              count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride else { return nil }
        let pointer = UnsafeRawPointer(bytes)
        let header = pointer.loadUnaligned(as: omni_wire_header.self)
        let node = pointer.loadUnaligned(
            fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self
        )
        return (node.width, header.deps)
    }
}

@MainActor
final class ShellSystemControlTests: XCTestCase {
    private struct Write: Equatable {
        let display: CGDirectDisplayID
        let value: Double
    }

    @MainActor
    private final class Display {
        var id: CGDirectDisplayID = 42
        var level: Double? = 0.5
        var reads: [CGDirectDisplayID] = []
        var writes: [Write] = []
        var succeeds = true
        var setterAvailable = true

        var access: ShellBrightnessAccess {
            ShellBrightnessAccess(
                display: { self.id },
                read: { [self] display in
                    reads.append(display)
                    return level
                },
                set: setterAvailable ? { [self] display, value in
                    writes.append(Write(display: display, value: value))
                    if succeeds { level = value }
                    return succeeds
                } : nil
            )
        }
    }

    func testBrightnessCommandsAreFiniteBoundedAndExplicit() {
        XCTAssertEqual(ShellAction("brightness set 0"), .brightness(.set(percent: 0)))
        XCTAssertEqual(ShellAction("brightness set 42.5"), .brightness(.set(percent: 42.5)))
        XCTAssertEqual(ShellAction("brightness set 100"), .brightness(.set(percent: 100)))
        XCTAssertEqual(ShellAction("brightness up"), .brightness(.change(percent: 6.25)))
        XCTAssertEqual(ShellAction("brightness down"), .brightness(.change(percent: -6.25)))
        XCTAssertEqual(ShellAction("brightness settings"), .settings(.brightness))
        for command in [
            "brightness",
            "brightness set",
            "brightness set nan",
            "brightness set inf",
            "brightness set -1",
            "brightness set 101",
            "brightness up 5",
            "brightness toggle"
        ] {
            XCTAssertNil(ShellAction(command), command)
        }
    }

    func testLiveCapabilityProbeOnlyReadsAndAcceptsUnsupportedHardware() {
        let access = ShellBrightnessAccess.live
        let snapshot = access.snapshot(for: access.display())
        if snapshot.available {
            XCTAssertTrue(snapshot.value.isFinite)
            XCTAssertTrue((0 ... 100).contains(snapshot.value))
        } else {
            XCTAssertEqual(snapshot.value, 0)
        }
    }

    func testMissingOrInvalidCapabilitiesNeverInvokeASetter() {
        for level: Double? in [nil, .nan, .infinity, -0.01, 1.01] {
            let display = Display()
            display.level = level
            let monitor = ShellDisplayBrightness(access: display.access)
            monitor.setListening(true)
            XCTAssertEqual(monitor.value, ShellBrightness())
            XCTAssertFalse(monitor.perform(.set(percent: 50)))
            XCTAssertFalse(monitor.perform(.change(percent: 6.25)))
            XCTAssertTrue(display.writes.isEmpty)
        }
        let display = Display()
        display.setterAvailable = false
        let monitor = ShellDisplayBrightness(access: display.access)
        monitor.setListening(true)
        XCTAssertEqual(monitor.value, ShellBrightness())
        XCTAssertFalse(monitor.perform(.set(percent: 50)))
        XCTAssertTrue(display.reads.isEmpty)
        XCTAssertTrue(display.writes.isEmpty)
    }

    func testDemandReadsOnceAndExternalChangesWaitForACommandOrReactivation() {
        let display = Display()
        let monitor = ShellDisplayBrightness(access: display.access)
        var values: [ShellBrightness?] = []
        monitor.onChange = { values.append($0) }
        XCTAssertTrue(display.reads.isEmpty)
        monitor.setListening(true)
        XCTAssertEqual(display.reads, [42])
        XCTAssertEqual(monitor.value, ShellBrightness(value: 50, available: true))
        monitor.setListening(true)
        XCTAssertEqual(display.reads, [42])
        display.level = 0.75
        XCTAssertEqual(monitor.value?.value, 50)
        monitor.setListening(false)
        XCTAssertNil(monitor.value)
        XCTAssertTrue(display.writes.isEmpty)
        monitor.setListening(true)
        XCTAssertEqual(display.reads, [42, 42])
        XCTAssertEqual(monitor.value, ShellBrightness(value: 75, available: true))
        XCTAssertEqual(values.compactMap { $0?.value }, [50, 75])
    }

    func testWritesUseTheCurrentMainDisplayAndRefreshFromTheReadback() {
        let display = Display()
        let monitor = ShellDisplayBrightness(access: display.access)
        monitor.setListening(true)
        XCTAssertTrue(monitor.perform(.set(percent: 25)))
        XCTAssertEqual(display.writes, [Write(display: 42, value: 0.25)])
        XCTAssertEqual(monitor.value?.value, 25)
        display.id = 7
        XCTAssertTrue(monitor.perform(.change(percent: 6.25)))
        XCTAssertEqual(display.writes.last, Write(display: 7, value: 0.3125))
        XCTAssertEqual(monitor.value?.value, 31.25)
        display.level = 0.99
        XCTAssertTrue(monitor.perform(.change(percent: 6.25)))
        XCTAssertEqual(display.writes.last?.value, 1)
        display.level = 0.01
        XCTAssertTrue(monitor.perform(.change(percent: -6.25)))
        XCTAssertEqual(display.writes.last?.value, 0)
    }

    func testInvalidDirectCommandsAndFailedWritesDoNotInventAValue() {
        let display = Display()
        let monitor = ShellDisplayBrightness(access: display.access)
        monitor.setListening(true)
        for percent in [-1.0, 101, .nan, .infinity] {
            XCTAssertFalse(monitor.perform(.set(percent: percent)))
        }
        XCTAssertFalse(monitor.perform(.change(percent: .infinity)))
        XCTAssertTrue(display.writes.isEmpty)
        display.succeeds = false
        XCTAssertFalse(monitor.perform(.set(percent: 25)))
        XCTAssertEqual(monitor.value, ShellBrightness(value: 50, available: true))
        XCTAssertEqual(display.writes, [Write(display: 42, value: 0.25)])
    }

    func testDeviceFeedClearsBrightnessOnDemandLossPauseAndStop() {
        let display = Display()
        let monitor = ShellDisplayBrightness(access: display.access)
        let feed = ShellDataFeed(devices: ShellDevices(brightness: monitor), deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertTrue(display.reads.isEmpty)
        let demand = ShellDataKey.brightness.bit
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        XCTAssertEqual(feed.current.brightness, ShellBrightness(value: 50, available: true))
        XCTAssertEqual(display.reads, [42])
        XCTAssertTrue(monitor.perform(.set(percent: 25)))
        XCTAssertEqual(feed.current.brightness?.value, 25)
        feed.setPaused(true)
        XCTAssertNil(feed.current.brightness)
        XCTAssertNil(monitor.value)
        feed.setPaused(false)
        XCTAssertEqual(feed.current.brightness?.value, 25)
        feed.setDemand(0, cadence: .init())
        XCTAssertNil(feed.current.brightness)
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        XCTAssertEqual(feed.current.brightness?.value, 25)
        feed.stop()
        XCTAssertNil(feed.current.brightness)
        XCTAssertNil(monitor.value)
    }

    func testBrightnessGetsOneAppendedDependencyBit() {
        XCTAssertEqual(ShellDataKey.microphone.bit, 1 << 48)
        XCTAssertEqual(ShellDataKey.brightness.bit, 1 << 49)
        let empty = ShellWidgetData()
        var next = empty
        next.brightness = ShellBrightness(value: 50, available: true)
        XCTAssertEqual(next.changedKeys(from: empty), ShellDataKey.brightness.bit)
        XCTAssertEqual(next.changedKeys(from: next), 0)
    }

    func testPackagePublishesBrightnessAndItsUnavailableAndAbsentStates() async {
        let package = ShellWidgetPackage(name: "brightness", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            local brightness = ctx.data.brightness
            if brightness then assert(type(brightness.available) == 'boolean') end
            return ui.box{w=brightness and (brightness.available and brightness.value or 2) or 1,h=10}
        end
        """)
        XCTAssertNil(failure)
        let key = ShellBarKey(monitor: .init(displayId: 96601))
        await package.receive(.bars([key: ShellBarData()]))
        var data = ShellWidgetData()
        for (value, expected): (ShellBrightness?, Float) in [
            (ShellBrightness(value: 36, available: true), 36), (ShellBrightness(), 2), (nil, 1)
        ] {
            data.brightness = value
            await package.receive(.update(data))
            let output = await package.systemControlOutput(key)
            XCTAssertEqual(output?.width, expected)
            XCTAssertEqual(output?.demand, ShellDataKey.brightness.bit)
        }
        await package.close()
    }

    func testRadiosKeepSettingsHandoffsWithoutPretendingWriteCapabilityWasProven() {
        XCTAssertEqual(ShellAction("wifi settings"), .settings(.wifi))
        XCTAssertEqual(ShellAction("bluetooth settings"), .settings(.bluetooth))
        XCTAssertEqual(
            ShellSettingsPane.brightness.url?.absoluteString,
            "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        )
        for command in ["wifi power on", "wifi power off", "bluetooth power on", "bluetooth power off"] {
            XCTAssertNil(ShellAction(command), command)
        }
    }
}
