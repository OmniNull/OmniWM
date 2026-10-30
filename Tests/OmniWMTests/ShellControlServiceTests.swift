// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreAudio
@testable import OmniWM
import OmniWMScriptHost
import XCTest

extension ShellWidgetPackage {
    fileprivate func controlOutput(_ key: ShellBarKey) -> (width: Float, demand: UInt64)? {
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
final class ShellControlServiceTests: XCTestCase {
    @MainActor
    private final class ControlEnvironment {
        var deadline: (@MainActor () -> Void)?
        var listenerAdds = 0
        var listenerRemoves = 0

        func manager() -> SleepPreventionManager {
            SleepPreventionManager(
                now: { Date(timeIntervalSince1970: 1000) },
                scheduleDeadline: { [self] _, action in
                    deadline = action
                    return { self.deadline = nil }
                },
                createAssertion: { 1 }, releaseAssertion: { _ in }, observeWorkspace: false
            )
        }

        func microphone() -> ShellMicrophoneMonitor {
            ShellMicrophoneMonitor(access: ShellMicrophoneAccess(
                defaultDevice: { nil }, read: { _ in ShellMicrophone() },
                setVolume: { _, _ in XCTFail("Unexpected hardware write")
                    return false
                },
                setMuted: { _, _ in XCTFail("Unexpected hardware write")
                    return false
                },
                addListener: { [self] _, _, _ in listenerAdds += 1
                    return noErr
                },
                removeListener: { [self] _, _, _ in listenerRemoves += 1
                    return noErr
                }
            ))
        }
    }

    func testActionsRouteToTheirExistingOwnersAndRejectInvalidCommands() {
        XCTAssertEqual(ShellAction("session awake on"), .awake(.on))
        XCTAssertEqual(ShellAction("session awake 30"), .awake(.timed(minutes: 30)))
        XCTAssertEqual(ShellAction("session awake off"), .awake(.off))
        XCTAssertEqual(ShellAction("microphone set 40"), .microphone(.set(percent: 40)))
        XCTAssertEqual(ShellAction("microphone mute"), .microphone(.toggleMute))
        XCTAssertEqual(ShellAction("calendar day 2024-02-29"), .calendar(.day("2024-02-29")))
        XCTAssertEqual(ShellAction("reminders add Call mom"), .reminders(.add(text: "Call mom")))
        for text in [
            "session awake",
            "session awake 0",
            "session awake nan",
            "microphone set inf",
            "microphone set -1",
            "microphone mute now",
            "calendar day 2024-02-30",
            "reminders add"
        ] {
            XCTAssertNil(ShellAction(text), text)
        }
    }

    func testSystemHandoffsUseTheVerifiedSettingsAndScreenshotURLs() {
        XCTAssertEqual(ShellAction("focus settings"), .settings(.focus))
        XCTAssertEqual(ShellAction("screenshot settings"), .settings(.screenshot))
        XCTAssertEqual(
            ShellSettingsPane.focus.url?.absoluteString,
            "x-apple.systempreferences:com.apple.Focus-Settings.extension"
        )
        XCTAssertEqual(ShellSettingsPane.screenshot.url?.path, "/System/Applications/Utilities/Screenshot.app")
        XCTAssertEqual(
            ShellSettingsPane.battery.url?.absoluteString,
            "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        )
    }

    func testAddedKeysKeepOldOrderingAndChangeIndependently() {
        XCTAssertEqual(ShellDataKey.notifications.bit, 1 << 46)
        XCTAssertEqual(ShellDataKey.awake.bit, 1 << 47)
        XCTAssertEqual(ShellDataKey.microphone.bit, 1 << 48)
        let empty = ShellWidgetData()
        var next = empty
        next.awake = ShellAwake(on: false, until: nil)
        XCTAssertEqual(next.changedKeys(from: empty), ShellDataKey.awake.bit)
        let awake = next
        next.microphone = ShellMicrophone(volume: 36, muted: false)
        XCTAssertEqual(next.changedKeys(from: awake), ShellDataKey.microphone.bit)
        XCTAssertEqual(next.changedKeys(from: empty), ShellDataKey.awake.bit | ShellDataKey.microphone.bit)
    }

    func testBothFeedsHydrateAndClearWithIsolatedDependencyBits() async throws {
        let package = ShellWidgetPackage(name: "controls", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            local awake, mic = ctx.data.awake, ctx.data.microphone
            if awake then assert(awake.on and awake["until"] == 900) end
            if mic then assert(mic.muted == false) end
            return ui.box{w=(awake and 100 or 1)+(mic and mic.volume or 0),h=10}
        end
        """)
        XCTAssertNil(failure)
        let key = ShellBarKey(monitor: .init(displayId: 96501))
        await package.receive(.bars([key: ShellBarData()]))
        let initial = await package.controlOutput(key)
        XCTAssertEqual(initial?.width, 1)
        let deps = ShellDataKey.awake.bit | ShellDataKey.microphone.bit
        XCTAssertEqual(initial?.demand, deps)
        var data = ShellWidgetData()
        data.awake = ShellAwake(on: true, until: 900)
        data.microphone = ShellMicrophone(volume: 36, muted: false)
        await package.receive(.update(data))
        let updated = await package.controlOutput(key)
        XCTAssertEqual(updated?.width, 136)
        XCTAssertEqual(updated?.demand, deps)
        await package.receive(.update(ShellWidgetData()))
        let cleared = await package.controlOutput(key)
        XCTAssertEqual(cleared?.width, 1)
        XCTAssertEqual(cleared?.demand, deps)
        await package.close()
    }

    func testFeedDemandPauseAndStopDetachWithoutChangingTheAwakeReason() {
        let environment = ControlEnvironment()
        let manager = environment.manager()
        let feed = ShellDataFeed(awakeManager: manager, microphone: environment.microphone(), deliver: { _ in })
        defer { feed.stop() }
        let deps = ShellDataKey.awake.bit | ShellDataKey.microphone.bit
        feed.setDemand(deps, cadence: .of([(deps, nil)]))
        XCTAssertEqual(environment.listenerAdds, 0)
        XCTAssertNil(feed.current.awake)
        feed.start()
        XCTAssertEqual(feed.current.awake, ShellAwake(on: false, until: nil))
        XCTAssertEqual(feed.current.microphone, ShellMicrophone())
        XCTAssertEqual(environment.listenerAdds, 1)
        manager.perform(.timed(minutes: 15))
        XCTAssertEqual(feed.current.awake?.until, 1900)
        feed.setPaused(true)
        XCTAssertEqual(environment.listenerRemoves, 1)
        XCTAssertNil(feed.current.awake)
        XCTAssertNil(feed.current.microphone)
        XCTAssertTrue(manager.awake.on)
        environment.deadline?()
        XCTAssertFalse(manager.awake.on)
        feed.setPaused(false)
        XCTAssertEqual(environment.listenerAdds, 2)
        XCTAssertEqual(feed.current.awake, ShellAwake(on: false, until: nil))
        feed.setDemand(0, cadence: .init())
        XCTAssertEqual(environment.listenerRemoves, 2)
        XCTAssertNil(feed.current.awake)
        manager.perform(.on)
        XCTAssertNil(feed.current.awake)
        feed.setDemand(deps, cadence: .of([(deps, nil)]))
        XCTAssertEqual(feed.current.awake, ShellAwake(on: true, until: nil))
        XCTAssertEqual(environment.listenerAdds, 3)
        feed.stop()
        XCTAssertEqual(environment.listenerRemoves, 3)
        XCTAssertNil(feed.current.awake)
        XCTAssertNil(feed.current.microphone)
        XCTAssertTrue(manager.awake.on)
        manager.perform(.off)
    }

    func testSelectedDayAndItsReminderSnapshotHydrateWithCalendarDemandOnly() async {
        let package = ShellWidgetPackage(name: "day", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            local cal = ctx.data.calendar
            if cal then
                assert(cal.selectedDay == "2024-02-29" and cal.access == "full")
                assert(cal.reminders.access == "full" and #cal.reminders.items == 1)
                assert(cal.reminders.items[1].title == "Call mom")
                assert(cal.reminders.items[1].allDay and cal.reminders.error == nil)
            end
            return ui.box{w=cal and cal.reminders.total or 0,h=10}
        end
        """)
        XCTAssertNil(failure)
        let key = ShellBarKey(monitor: .init(displayId: 96502))
        await package.receive(.bars([key: ShellBarData()]))
        var data = ShellWidgetData()
        data.calendar = ShellCalendar(
            access: "full", selectedDay: "2024-02-29", reminders: ShellReminders.bounded([
                ShellReminder(
                    id: "r1",
                    title: "Call mom",
                    list: "Home",
                    color: "#000000",
                    due: 100,
                    allDay: true,
                    priority: 0,
                    canComplete: true
                )
            ])
        )
        await package.receive(.update(data))
        let output = await package.controlOutput(key)
        XCTAssertEqual(output?.width, 1)
        XCTAssertEqual(output?.demand, ShellDataKey.calendar.bit)
        await package.close()
    }
}
