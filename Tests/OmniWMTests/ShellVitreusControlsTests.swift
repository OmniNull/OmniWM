// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusControlsTests: XCTestCase {
    let cu = 1.5525

    private struct Timer {
        let owner: omni_owner_token
        let id: UInt64
        let revision: UInt64
        let seconds: Double
        let cancelled: Bool
    }

    func fixture(animations: Bool = false) throws -> ShellRenderedWidget {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let source = try VitreusFixture.source(shell)
        let config = try VitreusFixture.config(shell)
        let widget = try ShellRenderedWidget(
            name: source.chunk, source: source.main,
            directories: [try XCTUnwrap(config.widget("vitreus")).deletingLastPathComponent()] + config.directories,
            modules: source.modules, chunk: source.chunk, scale: 2,
            resources: VitreusFixture.resources(shell, animations: animations),
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders),
            memoryLimit: ShellWidgetPackage.memoryLimit, moduleLimit: source.moduleLimit
        )
        widget.configure(ShellComponentCatalog.configurationBytes(
            instances: source.components, descriptors: source.componentDescriptors
        ))
        VitreusFixture.settings(widget, ["pieces": .strings(["controls"])])
        widget.set("wifi") {
            ShellWiFi(
                power: true,
                connected: true,
                ssid: "Test Network",
                rssi: -45,
                band: "5 GHz",
                channel: 36,
                security: "WPA3 Personal",
                location: "authorized"
            ).write(into: &$0)
        }
        widget.set("bluetooth") {
            ShellBluetooth(power: true, access: "granted", devices: [.init(
                id: "device-one", name: "Test Headphones", kind: "headphones", connected: true, battery: 72
            )]).write(into: &$0)
        }
        widget.set("awake") { ShellAwake(on: false, until: nil).write(into: &$0) }
        widget.set("brightness") { ShellBrightness(value: 62, available: true).write(into: &$0) }
        widget.set("microphone") { ShellMicrophone(volume: 45, muted: false).write(into: &$0) }
        widget.set("volume") { $0.number(76) }
        widget.set("muted") { $0.bool(false) }
        widget.set("battery") { $0.number(68) }
        widget.set("charging") { $0.bool(true) }
        widget.set("notifications") { ShellNotificationsData(state: "empty").write(into: &$0) }
        show(widget)
        VitreusFixture.trigger(widget.instance, "drawer-controls", VitreusFixture.bar().monitorId)
        show(widget)
        omni_instance_clear_messages(widget.instance)
        _ = timers(widget)
        return widget
    }

    private func show(_ widget: ShellRenderedWidget) {
        widget.set("seconds") { $0.number(1000) }
        widget.set("island") { VitreusFixture.island(VitreusFixture.monitor()).write(to: &$0) }
        widget.render(VitreusFixture.bar())
        widget.surface.view.frame = CGRect(origin: .zero, size: widget.surface.size)
    }

    private func content(_ widget: ShellRenderedWidget, _ key: String) throws -> Content {
        widget.surface.layout.core.content(of: try VitreusFixture.element(widget, key: key))
    }

    func invoke(_ widget: ShellRenderedWidget, _ key: String) throws -> [String] {
        let node = try content(widget, key)
        let commands: [String]
        if node.action & OMNI_ACTION_HANDLER != 0 { commands = widget.invoke(node.action) }
        else { commands = [widget.text.string(node.action)] }
        show(widget)
        return commands
    }

    private func press(_ widget: ShellRenderedWidget, _ key: String, _ phase: ShellEvent.Phase) throws -> [String] {
        let node = try content(widget, key)
        return widget.invoke(node.pressAction, event: ShellEvent(phase: phase))
    }

    private func has(_ widget: ShellRenderedWidget, _ key: String) -> Bool {
        ShellVitreusBarTests.has(widget, key)
    }

    private func dependencies(_ widget: ShellRenderedWidget) -> UInt64 {
        widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
    }

    private func timers(_ widget: ShellRenderedWidget) -> [Timer] {
        var raw = omni_service_request()
        var result: [Timer] = []
        while omni_vm_next_service(widget.vm, &raw) {
            if raw.kind == OMNI_SERVICE_TIMER {
                result.append(Timer(
                    owner: raw.owner,
                    id: raw.id,
                    revision: raw.revision,
                    seconds: raw.seconds,
                    cancelled: raw.cancelled
                ))
            }
        }
        return result
    }

    private func complete(_ widget: ShellRenderedWidget, _ timer: Timer) -> (Bool, [String]) {
        var handled = false
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(omni_vm_complete_service(
            widget.vm, timer.owner, timer.id, timer.revision, nil, 0, 100_000_000,
            &handled, &error, error.count
        ), OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        defer { omni_vm_clear_messages(widget.vm) }
        let commands = (0 ..< omni_vm_message_count(widget.vm, OMNI_MESSAGE_REQUEST)).map { index in
            var count = 0
            let bytes = omni_vm_message(widget.vm, OMNI_MESSAGE_REQUEST, index, &count)
            return bytes.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: count), as: UTF8.self) } ?? ""
        }
        return (handled, commands)
    }
}

extension ShellVitreusControlsTests {
    func testSixTileAndSliderGeometryAndProviderState() throws {
        let widget = try fixture()
        let panel = try VitreusFixture.frame(widget, key: "drawer-content-controls")
        XCTAssertEqual(panel.width, 312 * cu, accuracy: 0.001)
        XCTAssertEqual(panel.height, 322 * cu, accuracy: 0.001)
        for (index, name) in ["wifi", "caffeine", "notifications", "bluetooth", "capture", "power"].enumerated() {
            let frame = try VitreusFixture.frame(widget, key: "controls-tile-" + name)
            XCTAssertEqual(frame.width, 94 * cu, accuracy: 0.001)
            XCTAssertEqual(frame.height, 72 * cu, accuracy: 0.001)
            XCTAssertEqual(frame.minX - panel.minX, Double(12 + index % 3 * 97) * cu, accuracy: 0.001)
            XCTAssertEqual(frame.minY - panel.minY, Double(index < 3 ? 22 : 98) * cu, accuracy: 0.001)
        }
        for (name, center) in [("brightness", 186.0), ("microphone", 226), ("volume", 266)] {
            let frame = try VitreusFixture.frame(widget, key: "controls-" + name)
            XCTAssertEqual(frame.midY - panel.minY, (center + 14) * cu, accuracy: 0.001)
        }
        XCTAssertTrue(widget.strings().contains("Test Network"))
        XCTAssertTrue(widget.strings().contains("Test Headphones"))
        XCTAssertEqual(dependencies(widget) & ShellDataKey.audioApps.bit, 0)
        XCTAssertEqual(dependencies(widget) & ShellDataKey.spectrum.bit, 0)
        XCTAssertFalse(has(widget, "controls-power-shatter-1"))
    }
}

extension ShellVitreusControlsTests {
    func testTileStatesFollowDataAndUseExistingHandOffs() throws {
        let widget = try fixture()
        for (key, command) in [
            ("wifi", "wifi settings"), ("bluetooth", "bluetooth settings"),
            ("notifications", "focus settings"), ("capture", "screenshot settings"),
            ("caffeine", "session awake on")
        ] {
            XCTAssertEqual(try invoke(widget, "controls-toggle-" + key), [command])
            XCTAssertNotNil(ShellAction(command))
        }
        widget.set("wifi") { ShellWiFi().write(into: &$0) }
        widget.set("bluetooth") { ShellBluetooth(power: false, access: "denied").write(into: &$0) }
        widget.set("awake") { ShellAwake(on: true, until: 2200).write(into: &$0) }
        show(widget)
        let strings = widget.strings()
        XCTAssertTrue(strings.contains("Off"))
        XCTAssertTrue(strings.contains("20 min"))
        XCTAssertEqual(try invoke(widget, "controls-toggle-caffeine"), ["session awake off"])
        let slot = try VitreusFixture.element(widget, key: "controls-icon-wifi").slot
        try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(widget.surface.scene.layers[slot])
            XCTAssertEqual(layer.shadowRadius, 2.4 * cu, accuracy: 0.001)
            XCTAssertEqual(layer.shadowOffset, .zero)
        }
    }

    func testUnavailableBrightnessHidesItsRowAndUnsupportedMicrophoneStaysHonest() throws {
        let widget = try fixture()
        widget.set("brightness") { ShellBrightness(value: 0, available: false).write(into: &$0) }
        widget.set("microphone") { ShellMicrophone().write(into: &$0) }
        show(widget)
        XCTAssertFalse(has(widget, "controls-brightness"))
        XCTAssertEqual(try invoke(widget, "controls-display-settings"), ["brightness settings"])
        let panel = try VitreusFixture.frame(widget, key: "drawer-content-controls")
        XCTAssertEqual(panel.height, 282 * cu, accuracy: 0.001)
        XCTAssertEqual(
            try VitreusFixture.frame(widget, key: "controls-microphone").midY - panel.minY,
            200 * cu,
            accuracy: 0.001
        )
        let input = try content(widget, "controls-microphone")
        XCTAssertEqual(input.pressAction, 0)
        XCTAssertEqual(input.gestureAction, 0)
        XCTAssertTrue(widget.strings().contains("Unavailable"))
    }

    func testMixerDemandsAudioOnlyWhileOpenAndGrowsOnCalm() throws {
        let widget = try fixture(animations: true)
        widget.set("audioApps") {
            ShellAudioApps(access: .granted, apps: [
                .init(id: "test.music", name: "Music", playing: true, volume: 50, muted: false),
                .init(id: "test.browser", name: "Browser", playing: false, volume: 80, muted: true)
            ]).write(into: &$0)
        }
        show(widget)
        XCTAssertEqual(dependencies(widget) & ShellDataKey.audioApps.bit, 0)
        XCTAssertEqual(try invoke(widget, "controls-mixer-toggle"), [])
        XCTAssertNotEqual(dependencies(widget) & ShellDataKey.audioApps.bit, 0)
        let panel = try VitreusFixture.frame(widget, key: "drawer-content-controls")
        XCTAssertEqual(panel.height, 394 * cu, accuracy: 0.001)
        let first = try VitreusFixture.frame(widget, key: "controls-app-test.music")
        let second = try VitreusFixture.frame(widget, key: "controls-app-test.browser")
        XCTAssertEqual(first.width, 288 * cu, accuracy: 0.001)
        XCTAssertEqual(second.minY - first.minY, 32 * cu, accuracy: 0.001)
        XCTAssertEqual(try invoke(widget, "controls-app-mute-test.browser"), ["volume app test.browser mute"])
        let element = try VitreusFixture.element(widget, key: "controls-slider-veil-shape")
        XCTAssertNotEqual(widget.surface.layout.core.content(of: element).motion, 0)
        XCTAssertEqual(try invoke(widget, "controls-mixer-toggle"), [])
        XCTAssertEqual(dependencies(widget) & ShellDataKey.audioApps.bit, 0)
        XCTAssertFalse(has(widget, "controls-app-test.music"))
        widget.set("audioApps") { ShellAudioApps(access: .denied).write(into: &$0) }
        _ = try invoke(widget, "controls-mixer-toggle")
        XCTAssertTrue(widget.strings().contains("Audio access denied"))
    }

    func testOutputListUsesNativeDevicesAndStopsMixerDemand() throws {
        let widget = try fixture()
        widget.set("outputs") { writer in
            writer.array(2)
            ShellAudioOutput(id: 42, name: "Speakers", transport: "builtin", isDefault: true).write(into: &writer)
            ShellAudioOutput(id: 87, name: "Headphones", transport: "bluetooth", isDefault: false).write(into: &writer)
        }
        _ = try invoke(widget, "controls-mixer-toggle")
        _ = try invoke(widget, "controls-outputs-toggle")
        XCTAssertEqual(dependencies(widget) & ShellDataKey.audioApps.bit, 0)
        XCTAssertNotEqual(dependencies(widget) & ShellDataKey.outputs.bit, 0)
        XCTAssertTrue(has(widget, "controls-output-42"))
        XCTAssertEqual(try invoke(widget, "controls-output-87"), ["volume output 87"])
        XCTAssertFalse(has(widget, "controls-output-42"))
        XCTAssertEqual(dependencies(widget) & ShellDataKey.outputs.bit, 0)
        _ = try invoke(widget, "controls-outputs-toggle")
        let footer = try VitreusFixture.frame(widget, key: "controls-mixer-toggle")
        let last = try VitreusFixture.frame(widget, key: "controls-output-87")
        XCTAssertGreaterThan(footer.minY, last.maxY)
        let before = widget.events.count
        widget.surface.press(at: CGPoint(x: footer.midX, y: footer.midY))
        widget.surface.release(at: CGPoint(x: footer.midX, y: footer.midY))
        let events = widget.events.dropFirst(before)
        XCTAssertFalse(events.isEmpty)
        let commands = events.flatMap { widget.invoke($0.action, event: $0.event) }
        XCTAssertEqual(commands, [])
        show(widget)
        XCTAssertFalse(has(widget, "controls-outputs"))
        XCTAssertTrue(has(widget, "controls-apps"))
    }

    func testSliderAndMuteCommandsNeverInvokeHardwareInTheFixture() throws {
        let widget = try fixture()
        for (key, command) in [
            ("brightness", "brightness set"),
            ("microphone", "microphone set"),
            ("volume", "volume set")
        ] {
            let node = try content(widget, "controls-" + key)
            var event = ShellEvent(phase: .down)
            event.x = (8 + 170 * 0.75) * cu
            XCTAssertEqual(widget.invoke(node.pressAction, event: event), [command + " 75.0"])
            event.phase = .up
            XCTAssertEqual(widget.invoke(node.pressAction, event: event), [])
            show(widget)
        }
        XCTAssertEqual(try invoke(widget, "controls-microphone-mute"), ["microphone mute"])
        XCTAssertEqual(try invoke(widget, "controls-volume-mute"), ["volume mute"])
        _ = try invoke(widget, "controls-tile-bluetooth")
        XCTAssertTrue(widget.strings().contains("Test Headphones"))
        XCTAssertEqual(try invoke(widget, "controls-bluetooth-device-one"), ["bluetooth settings"])
        _ = try invoke(widget, "controls-back")
        _ = try invoke(widget, "controls-tile-capture")
        XCTAssertEqual(try invoke(widget, "controls-capture-settings"), ["screenshot settings"])
        _ = try invoke(widget, "controls-back")
        _ = try invoke(widget, "controls-tile-power")
        for mode in ["saver", "balanced", "performance"] {
            XCTAssertEqual(try invoke(widget, "controls-power-mode-" + mode), ["battery settings"])
        }
    }
}

extension ShellVitreusControlsTests {
    func testCaffeineSevenStopsUseTimedAwakeAndTheProviderOwnsState() throws {
        let widget = try fixture()
        _ = try invoke(widget, "controls-tile-caffeine")
        for (index, command) in ["off", "15", "30", "60", "120", "240", "on"].enumerated() {
            XCTAssertEqual(try invoke(widget, "controls-awake-stop-\(index)"), ["session awake " + command])
        }
        widget.set("awake") { ShellAwake(on: true, until: 4600).write(into: &$0) }
        show(widget)
        XCTAssertTrue(has(widget, "controls-awake-ring"))
        XCTAssertTrue(widget.strings().contains("60m"))
        let panel = try VitreusFixture.frame(widget, key: "drawer-content-controls")
        XCTAssertEqual(
            try VitreusFixture.frame(widget, key: "controls-awake-thumb").midY - panel.minY,
            248 * cu,
            accuracy: 0.001
        )
        widget.set("awake") { ShellAwake(on: false, until: nil).write(into: &$0) }
        show(widget)
        XCTAssertFalse(has(widget, "controls-awake-ring"))
    }

    func testNotificationHistoryAndDNDUseTheExistingNotificationAndFocusOwners() throws {
        let widget = try fixture()
        let id = "923481a3-dcc7-473b-89aa-14f4435d3471"
        widget.set("notifications") {
            ShellNotificationsData(state: "ready", items: [.object([
                "id": .text(id), "bundle": .text("test.mail"), "title": .text("A message"),
                "body": .text("A notification from the existing bridge")
            ])]).write(into: &$0)
        }
        XCTAssertEqual(try invoke(widget, "controls-tile-notifications"), ["notifications refresh"])
        XCTAssertTrue(has(widget, "controls-notification-" + id))
        XCTAssertEqual(
            try invoke(widget, "controls-notification-dismiss-" + id),
            ["notifications dismiss test.mail " + id]
        )
        XCTAssertEqual(try invoke(widget, "controls-notifications-clear"), ["notifications dismiss-all"])
        XCTAssertEqual(try invoke(widget, "controls-notifications-focus"), ["focus settings"])
        widget.set("notifications") {
            ShellNotificationsData(state: "ready", items: [.object([
                "id": .text(id), "bundle": .text("test.mail"), "title": .text("A message"), "body": .text("")
            ])], dispatched: [id]).write(into: &$0)
        }
        show(widget)
        XCTAssertFalse(has(widget, "controls-notification-" + id))
        XCTAssertTrue(widget.strings().contains("All clear"))
        widget.set("notifications") { ShellNotificationsData(state: "accessDenied").write(into: &$0) }
        show(widget)
        XCTAssertTrue(widget.strings().contains("Allow notification history in Settings"))
    }

    func testEveryPowerActionRequiresExactlyOneOneSecondHoldAndOneShotCleanup() throws {
        let widget = try fixture()
        _ = try invoke(widget, "controls-tile-power")
        for (index, command) in ["lock", "sleep", "logout", "restart", "shutdown"].enumerated() {
            XCTAssertEqual(try press(widget, "controls-power-" + command, .down), [])
            let timer = try XCTUnwrap(timers(widget).first { !$0.cancelled })
            XCTAssertEqual(timer.seconds, 1)
            show(widget)
            XCTAssertTrue(widget.strings().contains("Hold 1s"))
            let result = complete(widget, timer)
            XCTAssertTrue(result.0)
            XCTAssertEqual(result.1, ["session " + command])
            XCTAssertNotNil(ShellAction(try XCTUnwrap(result.1.first)))
            XCTAssertFalse(complete(widget, timer).0)
            show(widget)
            XCTAssertTrue(has(widget, "controls-power-shatter-\(index + 1)"))
            let cleanup = try XCTUnwrap(timers(widget).first { !$0.cancelled })
            XCTAssertEqual(cleanup.seconds, 0.95)
            XCTAssertEqual(complete(widget, cleanup).1, [])
            show(widget)
            XCTAssertFalse(has(widget, "controls-power-shatter-\(index + 1)"))
        }
    }

    func testPowerHoldCancelsOnReleaseCancelBackDrawerSwitchAndDisplayDismissal() throws {
        let widget = try fixture()
        _ = try invoke(widget, "controls-tile-power")
        for phase in [ShellEvent.Phase.up, .cancel] {
            _ = try press(widget, "controls-power-shutdown", .down)
            let timer = try XCTUnwrap(timers(widget).first { !$0.cancelled })
            _ = try press(widget, "controls-power-shutdown", phase)
            XCTAssertEqual(timers(widget).filter(\.cancelled).map(\.id), [timer.id])
            XCTAssertFalse(complete(widget, timer).0)
        }
        for destination in ["back", "calendar", "close", "other-display"] {
            if !has(widget, "controls-power-shutdown") {
                if !has(widget, "drawer-content-controls") {
                    VitreusFixture.trigger(widget.instance, "drawer-controls", VitreusFixture.bar().monitorId)
                    show(widget)
                }
                _ = try invoke(widget, "controls-tile-power")
            }
            _ = try press(widget, "controls-power-shutdown", .down)
            let timer = try XCTUnwrap(timers(widget).first { !$0.cancelled })
            if destination == "back" { _ = try invoke(widget, "controls-back") }
            else if destination == "calendar" {
                VitreusFixture.trigger(widget.instance, "drawer-calendar", VitreusFixture.bar().monitorId)
            } else {
                VitreusFixture.trigger(
                    widget.instance,
                    destination == "close" ? "drawer-close" : "drawer-selected",
                    destination == "close" ? VitreusFixture.bar().monitorId : "display:99999"
                )
            }
            XCTAssertTrue(timers(widget).contains { $0.cancelled && $0.id == timer.id })
            XCTAssertFalse(complete(widget, timer).0)
            show(widget)
        }
    }
}

extension ShellVitreusControlsTests {
    func testRealPointerDeliveryStartsAndCancelsTheHoldOutsideTheButton() throws {
        let widget = try fixture()
        _ = try invoke(widget, "controls-tile-power")
        let frame = try VitreusFixture.frame(widget, key: "controls-power-shutdown")
        var index = widget.events.count
        widget.surface.press(at: CGPoint(x: frame.midX, y: frame.midY))
        let press = try XCTUnwrap(widget.events.dropFirst(index).first { $0.event.kind == .press })
        XCTAssertEqual(press.event.phase, .down)
        XCTAssertEqual(widget.invoke(press.action, event: press.event), [])
        let timer = try XCTUnwrap(timers(widget).first { !$0.cancelled })
        show(widget)
        index = widget.events.count
        widget.surface.release(at: CGPoint(x: frame.maxX + 100, y: frame.maxY + 100))
        let release = try XCTUnwrap(widget.events.dropFirst(index).first { $0.event.kind == .press })
        XCTAssertTrue(release.event.phase == .up || release.event.phase == .cancel)
        XCTAssertEqual(widget.invoke(release.action, event: release.event), [])
        XCTAssertTrue(timers(widget).contains { $0.cancelled && $0.id == timer.id })
        XCTAssertFalse(complete(widget, timer).0)
    }

    func testAppSliderNativeDragAndTimerProgressHonorTheMotionPolicy() throws {
        let widget = try fixture()
        widget.set("audioApps") {
            ShellAudioApps(access: .granted, apps: [
                .init(id: "test.music", name: "Music", playing: true, volume: 50, muted: false)
            ]).write(into: &$0)
        }
        _ = try invoke(widget, "controls-mixer-toggle")
        let frame = try VitreusFixture.frame(widget, key: "controls-app-slider-test.music")
        let start = CGPoint(x: frame.minX + 8 * cu, y: frame.midY)
        let end = CGPoint(x: frame.minX + 83 * cu, y: frame.midY)
        let index = widget.events.count
        widget.surface.press(at: start)
        widget.surface.drag(to: end, screen: .zero)
        widget.surface.release(at: end)
        let commands = widget.events.dropFirst(index).flatMap { widget.invoke($0.action, event: $0.event) }
        XCTAssertTrue(commands.contains("volume app test.music set 75.0"))
        XCTAssertTrue(commands.allSatisfy { ShellAction($0) != nil })
        _ = try invoke(widget, "controls-tile-power")
        _ = try press(widget, "controls-power-lock", .down)
        show(widget)
        let slot = try VitreusFixture.element(widget, key: "controls-power-progress-lock").slot
        ShellLayerScene.engineQueue.sync {
            XCTAssertNil(widget.surface.scene.layers[slot]?.animation(forKey: "bounds"))
        }
        let animated = try fixture(animations: true)
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = animated.surface.scene.container
            root.frame = CGRect(origin: .zero, size: animated.surface.size)
            let result = try ShellOffscreenRenderer(root: root, width: 1920, height: 1080)
            root.speed = 0
            root.timeOffset = 30
            return result
        }
        _ = try invoke(animated, "controls-tile-power")
        _ = try press(animated, "controls-power-lock", .down)
        show(animated)
        let animatedSlot = try VitreusFixture.element(animated, key: "controls-power-progress-lock").slot
        try ShellLayerScene.engineQueue.sync {
            let animation = try XCTUnwrap(animated.surface.scene.layers[animatedSlot]?.animation(forKey: "bounds"))
            XCTAssertEqual(animation.duration, 1)
            XCTAssertEqual(animation.timingFunction, CAMediaTimingFunction(name: .linear))
            _ = try renderer.render(paused: 30.5)
        }
    }
}
