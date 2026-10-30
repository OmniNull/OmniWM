// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusDrawerTests: XCTestCase {
    final class Clock {
        var time = CACurrentMediaTime()
        var elapsed = 0.0
    }

    struct Fixture {
        let widget: ShellRenderedWidget
        let monitor: Monitor
        let clock: Clock
        let scene: ShellLayerScene
    }

    func fixture(animations: Bool = false, display: UInt32 = 95100) throws -> Fixture {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let source = try VitreusFixture.source(shell)
        let modules = source.modules.map { module -> ShellWidgetSource.Module in
            module.path.hasSuffix("lib/vitreus/drawer.luau") ? .init(
                path: module.path,
                source:
                "local testClock=require('./test-clock') local os={clock=function() return testClock.now end,date=os.date}\n"
                    + module.source
            ) : module
        } + [.init(path: "vitreus/lib/vitreus/test-clock.luau", source: "return {now=0}")]
        let main = source.main + """

        local testClock = require('../lib/vitreus/test-clock')
        local rootTrigger = trigger
        function trigger(ctx,event)
            if event.name=='test-clock' then testClock.now=tonumber(event.value) return end
            rootTrigger(ctx,event)
        end
        """
        let widget = try ShellRenderedWidget(
            name: "vitreus-drawer", source: main, modules: modules, chunk: source.chunk,
            resources: VitreusFixture.resources(shell, animations: animations),
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders), memoryLimit: ShellWidgetPackage.memoryLimit,
            moduleLimit: source.moduleLimit
        )
        let clock = Clock()
        widget.surface.clock = { clock.time }
        let fixture = Fixture(
            widget: widget,
            monitor: VitreusFixture.monitor(id: display),
            clock: clock,
            scene: widget.surface.scene
        )
        seed(fixture)
        show(fixture)
        clock.time = CACurrentMediaTime()
        widget.surface.animates = animations
        return fixture
    }

    private func seed(_ fixture: Fixture, access: String = "full", error: String? = nil) {
        fixture.widget.set("calendar") { writer in
            ShellCalendar(access: "full", month: ShellCalendarMonth(
                title: "October 2026", year: 2026, month: 10, days: 31, offset: 3, today: 28,
                weekdays: ["M", "T", "W", "T", "F", "S", "S"], marked: [5, 28]
            ), selectedDay: "2026-10-28", reminders: ShellReminders(
                access: access, items: [.init(
                    id: "reminder-1",
                    title: "Call mom",
                    list: "Personal",
                    color: "#FFFFFF",
                    due: 1_793_210_400,
                    allDay: false,
                    priority: 0,
                    canComplete: true
                )],
                total: 1, error: error
            )).write(into: &writer)
        }
    }

    func show(_ fixture: Fixture) {
        fixture.widget.set("seconds") { $0.number(1_793_188_800) }
        fixture.widget.set("island") { VitreusFixture.island(fixture.monitor).write(to: &$0) }
        fixture.widget.render(VitreusFixture.bar(fixture.monitor))
        fixture.widget.surface.view.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
    }

    @discardableResult
    func trigger(_ fixture: Fixture, _ name: String, display: String? = nil) -> [String] {
        VitreusFixture.trigger(fixture.widget.instance, name, display ?? VitreusFixture.bar(fixture.monitor).monitorId)
        let requests = messages(fixture.widget)
        show(fixture)
        return requests
    }

    private func messages(_ widget: ShellRenderedWidget) -> [String] {
        defer { omni_instance_clear_messages(widget.instance) }
        return (0 ..< omni_instance_message_count(widget.instance, OMNI_MESSAGE_REQUEST)).map { index in
            var length = 0
            let value = omni_instance_message(widget.instance, OMNI_MESSAGE_REQUEST, index, &length)
            return value.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: length), as: UTF8.self) } ?? ""
        }
    }

    func advance(_ fixture: Fixture, by elapsed: Double) {
        fixture.clock.time += elapsed
        fixture.clock.elapsed += elapsed
        VitreusFixture.trigger(fixture.widget.instance, "test-clock", String(fixture.clock.elapsed))
        ShellLayerScene.engineQueue.sync { fixture.scene.container.timeOffset = fixture.clock.time }
    }

    func handle(_ fixture: Fixture, _ name: String) throws -> ElementHandle {
        try VitreusFixture.element(fixture.widget, key: name)
    }

    func has(_ fixture: Fixture, _ name: String) -> Bool {
        fixture.widget.surface.layout.core.elements { _ in true }.contains {
            fixture.widget.surface.layout.core.key(of: $0) == VitreusFixture.key(name)
        }
    }

    func morph(_ fixture: Fixture, _ name: String) throws -> ShellMorphRecipe {
        let paint = fixture.widget.surface.layout.core.paint(of: try handle(fixture, name))
        return try XCTUnwrap(ShellMorphRecipe(fixture.widget.text.string(paint.morph)))
    }

    private func track(_ fixture: Fixture) throws -> ShellShapeTrackEntry {
        let slot = try handle(fixture, "drawer").slot
        return try ShellLayerScene.engineQueue.sync { try XCTUnwrap(fixture.scene.shapeTracks.entries[slot]) }
    }
}

@MainActor
extension ShellVitreusDrawerTests {
    func testDripStopsLandingAndCloseImpulsesMatchTheReference() throws {
        let fixture = try fixture(animations: true)
        trigger(fixture, "drawer-calendar")
        let recipe = try morph(fixture, "drawer")
        let frame = try VitreusFixture.frame(fixture.widget, key: "drawer")
        for stop in recipe.stops {
            let progress = stop.at, clamped = min(1, progress)
            XCTAssertEqual(stop.scale, min(1, 1.6 * progress) + 0.6 * max(0, progress - 1), accuracy: 0.00001)
            XCTAssertEqual(stop.width, 1 - 0.07 * 4 * clamped * (1 - clamped), accuracy: 0.00001)
            XCTAssertEqual(stop.round, min(1, max(0, 1.6 * progress - 0.1)), accuracy: 0.00001)
        }
        XCTAssertEqual(frame.width, 450 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(frame.height, 20 * 1.35 + 373 * 1.5525, accuracy: 0.001)
        let landing = recipe.impulses.filter(\.rising)
        XCTAssertEqual(landing.count, 2)
        XCTAssertTrue(landing.allSatisfy { $0.time == 0.97 && $0.kind == .at })
        XCTAssertEqual(landing.map(\.velocity), [220, -260])
        XCTAssertEqual(landing.map(\.pivot), [.anchor, .centre])
        XCTAssertEqual(landing[0].spring.parameters.stiffness, 260, accuracy: 0.01)
        XCTAssertEqual(landing[0].spring.parameters.damping, 32, accuracy: 0.01)
        XCTAssertEqual(landing[1].spring.parameters.stiffness, 420, accuracy: 0.01)
        let close = try XCTUnwrap(recipe.impulses.first { !$0.rising })
        XCTAssertEqual(close.time, 0.08)
        XCTAssertEqual(close.velocity, 90)
        XCTAssertEqual(recipe.impulses.filter { $0.phase == .close }.map(\.velocity), [90])
        let entry = try track(fixture)
        let first = try XCTUnwrap(entry.plan?.crossings(at: 0.97, rising: true).first)
        XCTAssertEqual(first - entry.begin, 0.230, accuracy: 0.005)
        XCTAssertFalse(entry.impulses.contains { $0.velocity == 90 })
    }

    func testContentTranslationPlatesCalendarAndFocusUseProviderData() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-calendar")
        let recipe = try morph(fixture, "drawer-clip")
        XCTAssertEqual(recipe.stops.first?.dy ?? 0, -125 * 1.5525, accuracy: 0.001)
        XCTAssertEqual(recipe.stops.first?.scale, 0.05)
        XCTAssertEqual(recipe.stop(at: 1).dy, 0)
        let names = [
            "calendar-clock-plate",
            "calendar-reminders-plate",
            "calendar-month-plate",
            "calendar-weather-plate"
        ]
        let content = try VitreusFixture.frame(fixture.widget, key: "drawer-content-calendar")
        let expected = [
            CGRect(x: 12, y: 87, width: 166, height: 72),
            CGRect(x: 12, y: 165, width: 166, height: 154),
            CGRect(x: 184, y: 87, width: 254, height: 232),
            CGRect(x: 12, y: 19, width: 426, height: 60)
        ]
        for (name, rect) in zip(names, expected) {
            let actual = try VitreusFixture.frame(fixture.widget, key: name).offsetBy(
                dx: -content.minX,
                dy: -content.minY
            )
            XCTAssertEqual(actual.minX, rect.minX * 1.5525, accuracy: 0.001)
            XCTAssertEqual(actual.minY, rect.minY * 1.5525, accuracy: 0.001)
            XCTAssertEqual(actual.width, rect.width * 1.5525, accuracy: 0.001)
            XCTAssertEqual(actual.height, rect.height * 1.5525, accuracy: 0.001)
        }
        XCTAssertTrue(fixture.widget.strings().contains("October 2026"))
        XCTAssertTrue(fixture.widget.strings().contains("Call mom"))
        let nodes = fixture.widget.tree()
        XCTAssertEqual(nodes.filter { $0.kind == .input }.count, 1)
        XCTAssertEqual(try XCTUnwrap(nodes.first { $0.kind == .input }).content.inputFocus, 1)
        for (name, delay) in [("calendar-f1", 0.22), ("calendar-f4", 0.30)] {
            let paint = fixture.widget.surface.layout.core.paint(of: try handle(fixture, name))
            let presence = try XCTUnwrap(ShellPresenceRecipe(fixture.widget.text.string(paint.appear)))
            XCTAssertEqual(presence.delay, delay)
            XCTAssertEqual(presence.offset.y, 12 * 1.5525, accuracy: 0.001)
            XCTAssertNotEqual(paint.exit, 0)
        }
    }

    func testWeatherAndSelectedDayEventsComeFromProviderSnapshots() throws {
        let fixture = try fixture()
        fixture.widget.set("weather") { writer in
            ShellWeather(temp: 22, code: 0, day: true, unit: "C", days: [
                .init(time: 0, label: "Wed", high: 24, low: 16, code: 0, rain: nil),
                .init(time: 86400, label: "Thu", high: 20, low: 14, code: 3, rain: nil)
            ]).write(into: &writer)
        }
        fixture.widget.set("calendar") { writer in
            ShellCalendar(
                access: "full",
                events: [.init(
                    id: "event-1",
                    title: "Planning",
                    calendar: "Work",
                    color: "#FFFFFF",
                    start: 0,
                    end: 3600,
                    allDay: false,
                    location: nil,
                    time: "10:00 AM",
                    day: "Today"
                )],
                selectedDay: "2026-10-28",
                reminders: .init(access: "full")
            ).write(into: &writer)
        }
        trigger(fixture, "drawer-calendar")
        for text in ["Clear", "22°", "Wed", "Thu", "Planning", "10:00 AM"] {
            XCTAssertTrue(fixture.widget.strings().contains(text), text)
        }
        XCTAssertTrue(has(fixture, "calendar-event-event-1"))
        XCTAssertFalse(has(fixture, "calendar-weather-status"))
    }

    func testSwitchKeepsTheSharedTrackAndDoesNotReplayDropOrLanding() throws {
        let fixture = try fixture(animations: true)
        trigger(fixture, "drawer-calendar")
        let before = try handle(fixture, "drawer")
        advance(fixture, by: 2)
        trigger(fixture, "drawer-controls")
        XCTAssertEqual(try handle(fixture, "drawer"), before)
        XCTAssertFalse(try morph(fixture, "drawer").impulses.contains(where: \.rising))
        XCTAssertTrue(try morph(fixture, "drawer-clip").stops.allSatisfy { $0.dy == 0 })
        let entry = try track(fixture)
        XCTAssertEqual(entry.plan?.progress ?? -1, 1, accuracy: 0.002)
        XCTAssertFalse(entry.impulses.contains { $0.velocity == 90 })
        trigger(fixture, "drawer-close")
        let retired = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.scene.shapeTracks.entries.values.first { $0.carrier != nil })
        }
        XCTAssertTrue(retired.impulses.contains { $0.velocity == 90 })
        let layout = fixture.widget.surface.layout, glass = try handle(fixture, "bar")
        let shapes = layout.core.elements { _ in true }.filter { layout.core.parent(of: $0) == glass }
        XCTAssertEqual(shapes.map { layout.core.key(of: $0) }, [VitreusFixture.key("shell")])
    }

    func testDisplayBroadcastClosesOtherInstancesAndResetsTodayWithoutExecutingCommands() throws {
        let first = try fixture(), second = try fixture(display: 95101)
        trigger(second, "drawer-calendar")
        let requests = trigger(first, "drawer-calendar")
        XCTAssertTrue(requests.contains("calendar month today"))
        let day = try XCTUnwrap(requests.first { $0.hasPrefix("calendar day ") })
        XCTAssertNotNil(ShellCalendarDay(String(day.dropFirst("calendar day ".count))))
        let broadcast = "shell trigger vitreus drawer-selected display:95100"
        XCTAssertTrue(requests.contains(broadcast))
        trigger(second, "drawer-selected", display: "display:95100")
        XCTAssertFalse(has(second, "drawer"))
        XCTAssertNoThrow(try handle(first, "drawer"))
    }

    func testHitRegionsAndOutsidePressKeepTheBarAndCloseOnEitherMouseButton() throws {
        for button in [ShellEvent.Button.left, .right] {
            let fixture = try fixture()
            trigger(fixture, "drawer-calendar")
            let frame = try VitreusFixture.frame(fixture.widget, key: "drawer-content-calendar")
            XCTAssertEqual(fixture.widget.surface.outsidePressTargets.count, 1)
            XCTAssertFalse(fixture.widget.surface.containsShape(at: CGPoint(x: 10, y: 700)))
            XCTAssertTrue(fixture.widget.surface.containsShape(at: CGPoint(x: frame.midX, y: frame.midY)))
            let island = Self.island(fixture.widget, on: fixture.monitor)
            defer { island.close() }
            XCTAssertEqual(Self.press(island, fixture.widget, at: CGPoint(x: 960, y: 20), button: button), [true])
            show(fixture)
            XCTAssertNoThrow(try handle(fixture, "drawer"))
            XCTAssertEqual(Self.press(island, fixture.widget, at: CGPoint(x: 0, y: 700), button: button), [false])
            show(fixture)
            XCTAssertFalse(has(fixture, "drawer"))
        }
    }

    func testMonthDayAndReminderActionsAreDeliveredAndDraftIsQuoted() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-calendar")
        for (key, command) in [
            ("calendar-next", "calendar month next"),
            ("calendar-previous", "calendar month previous"),
            ("calendar-day-2026-10-28", "calendar day 2026-10-28")
        ] {
            try VitreusFixture.click(fixture.widget, key: key)
            XCTAssertEqual(fixture.widget.clicks.last?.action, command)
        }
        let input = try XCTUnwrap(fixture.widget.tree().first { $0.kind == .input })
        var event = ShellEvent()
        event.text = "  Call \"mom\" at 3:30pm  "
        let requests = fixture.widget.invoke(input.content.inputCommitAction, event: event)
        XCTAssertEqual(requests, ["reminders add \"Call \\\"mom\\\" at 3:30pm\""])
        show(fixture)
        let next = try XCTUnwrap(fixture.widget.tree().first { $0.kind == .input })
        XCTAssertNotEqual(next.key, input.key)
        XCTAssertEqual(fixture.widget.text.string(next.content.text), "Call \"mom\" at 3:30pm")
    }

    func testReducedMotionFinalizesShapeAndContentAndPermissionStatesStayHonest() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-calendar")
        let entry = try track(fixture)
        XCTAssertEqual(entry.duration, 0)
        XCTAssertEqual(entry.terminal.rect, entry.base.target.rect)
        XCTAssertNil(fixture.widget.surface.presentation)
        seed(fixture, access: "denied")
        show(fixture)
        XCTAssertTrue(fixture.widget.tree().allSatisfy { $0.kind != .input })
        XCTAssertTrue(fixture.widget.strings().contains("Open Reminders Privacy Settings"))
        XCTAssertNoThrow(try handle(fixture, "calendar-reminders-access"))
    }

    func testCloseImpulseCannotFireDuringAQuickReopeningReversal() throws {
        let fixture = try fixture(animations: true)
        trigger(fixture, "drawer-calendar")
        advance(fixture, by: 2)
        trigger(fixture, "drawer-close")
        advance(fixture, by: 0.2)
        trigger(fixture, "drawer-calendar")
        let entry = try track(fixture)
        let plan = try XCTUnwrap(entry.plan)
        XCTAssertLessThan(plan.velocity, 0)
        XCTAssertGreaterThan(plan.progress, 0.08)
        XCTAssertFalse(plan.crossings(at: 0.08, rising: false).isEmpty)
        XCTAssertFalse(entry.impulses.contains { $0.velocity == 90 && $0.begin >= entry.begin })
        XCTAssertTrue(entry.impulses.contains { $0.velocity == 220 })
    }

    func testQueuedReminderRetainsDraftAcrossProviderErrorsAndNewTyping() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-calendar")
        let input = try XCTUnwrap(fixture.widget.tree().first { $0.kind == .input })
        var event = ShellEvent()
        event.text = "Call mom"
        XCTAssertEqual(
            fixture.widget.invoke(input.content.inputCommitAction, event: event),
            ["reminders add \"Call mom\""]
        )
        show(fixture)
        seed(fixture, error: "save_failed")
        show(fixture)
        let restored = try XCTUnwrap(fixture.widget.tree().first { $0.kind == .input })
        XCTAssertEqual(fixture.widget.text.string(restored.content.text), "Call mom")
        XCTAssertNotEqual(restored.key, input.key)
        event.text = "Something else"
        fixture.widget.invoke(restored.content.action, event: event)
        show(fixture)
        XCTAssertEqual(fixture.widget.text.string(try XCTUnwrap(fixture.widget.tree().first { $0.kind == .input })
                .content.text), "Something else")
    }

    func testNativeDripAt84MillisecondsMatchesSamplerAndOpenCalendarHasPixels() throws {
        let fixture = try fixture(animations: true)
        let size = fixture.widget.surface.size
        let renderer = try renderer(fixture)
        trigger(fixture, "drawer-calendar")
        let entry = try track(fixture)
        XCTAssertGreaterThan(entry.duration, 0)
        let pill = try VitreusFixture.frame(fixture.widget, key: "shell")
        let cropRect = CGRect(x: 560, y: 0, width: 800, height: 720)
        let content = try handle(fixture, "bar-content").slot
        let opener = try handle(fixture, "desk-opener").slot
        let body = try VitreusFixture.body(fixture.widget, key: "bar")
        try silhouette(fixture, body: body, slots: [content, opener], only: true)
        advance(fixture, by: 0.084)
        let pixels = try ShellLayerScene.engineQueue.sync {
            let part = try XCTUnwrap(body.lockstepLayers(entry.base.target.slot).first)
            let animation = try XCTUnwrap(part.animation(forKey: "omni.glass.bounds"))
            XCTAssertEqual(animation.beginTime, entry.begin, accuracy: 1e-9)
            XCTAssertEqual(animation.duration, entry.duration, accuracy: 1e-9)
            return try renderer.render(paused: fixture.clock.time)
        }
        let cropped = crop(pixels, width: Int(size.width))
        try export(cropped, name: "vitreus-calendar-84ms")
        let actual = try bounds(cropped, width: 800).offsetBy(dx: 560, dy: 0)
        let expected = pill.union(entry.shape(at: entry.begin + 0.084).rect)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 1)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 1)
        advance(fixture, by: 2)
        try silhouette(fixture, body: body, slots: [content, opener], only: false)
        let open = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: fixture.clock.time) }
        let openCrop = self.crop(open, width: Int(size.width))
        let frame = try VitreusFixture.frame(fixture.widget, key: "calendar-month-plate")
        let index = (Int(frame.midY - cropRect.minY) * 800 + Int(frame.midX - cropRect.minX)) * 4
        XCTAssertGreaterThan(openCrop[index + 3], 60)
        XCTAssertGreaterThan(openCrop.enumerated().filter { $0.offset % 4 == 3 && $0.element > 200 }.count, 100)
        try export(openCrop, name: "vitreus-calendar-open")
    }

    private func silhouette(_ fixture: Fixture, body: ShellGlassBody, slots: [Int32], only: Bool) throws {
        try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
            for index in [0, 2, 3] { body.sdfLayers[index].isHidden = only }
            for slot in slots { fixture.scene.layers[slot]?.isHidden = only }
        }
    }

    private func renderer(_ fixture: Fixture) throws -> ShellOffscreenRenderer {
        let size = fixture.widget.surface.size
        return try ShellLayerScene.engineQueue.sync {
            fixture.scene.container.frame = CGRect(origin: .zero, size: size)
            fixture.scene.container.isGeometryFlipped = true
            fixture.scene.container.speed = 0
            fixture.scene.container.timeOffset = fixture.clock.time
            return try ShellOffscreenRenderer(
                root: fixture.scene.container,
                width: Int(size.width),
                height: Int(size.height)
            )
        }
    }

    private func bounds(_ pixels: [UInt8], width: Int) throws -> CGRect {
        var left = width, right = 0, top = pixels.count / width / 4, bottom = 0
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] >= 50 {
            let pixel = index / 4
            left = min(left, pixel % width)
            right = max(right, pixel % width)
            top = min(top, pixel / width)
            bottom = max(bottom, pixel / width)
        }
        XCTAssertLessThan(left, right)
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private func crop(_ pixels: [UInt8], width: Int) -> [UInt8] {
        var cropped: [UInt8] = []
        cropped.reserveCapacity(800 * 720 * 4)
        for row in 0 ..< 720 {
            let start = (row * width + 560) * 4
            cropped += pixels[start ..< start + 3200]
        }
        return cropped
    }

    private func export(_ pixels: [UInt8], name: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(
            width: 800,
            height: 720,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 3200,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        try ShellVitreusDeskTests.write(image, name: name)
    }
}
