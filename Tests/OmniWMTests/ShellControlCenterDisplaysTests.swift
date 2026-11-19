// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellControlCenterDisplaysTests: XCTestCase {
    func testDisplaysTabDemandsDisplayDataAndKeepsSettingsLinkWithoutData() throws {
        let widget = try makeWidget(tab: "overview")
        let tab = try XCTUnwrap(widget.renderPopout().first {
            widget.text.string($0.content.help) == ShellLocalizer.string("Displays", [])
        })
        let demand = ShellDataKey.brightness.bit | ShellDataKey.nightShift.bit
        XCTAssertEqual(renderDependencies(widget) & demand, 0)
        XCTAssertEqual(widget.invoke(tab.content.action, view: OMNI_VIEW_POPOUT), [])

        XCTAssertEqual(renderDependencies(widget) & demand, demand)
        XCTAssertTrue(sliders(widget).isEmpty)
        XCTAssertEqual(
            widget.strings(OMNI_VIEW_POPOUT).filter { $0 == ShellLocalizer.string("Unavailable", []) }.count,
            2
        )
        XCTAssertFalse(commands(widget).contains { $0.hasPrefix("night-shift ") })
        widget.layoutPopout()
        let settings = try XCTUnwrap(widget.surface.layout.core.elements {
            widget.text.string($0.action) == "brightness settings"
        }.first)
        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: settings))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        XCTAssertEqual(widget.clicks.last?.action, "brightness settings")
    }

    func testDisplaysSlidersPreviewCancelAndSetBrightnessOnRelease() throws {
        let widget = try makeWidget()
        let external = ShellBrightness.Display(
            id: "39535021-2F5F-411E-892E-DAE27F950B92", name: "External", value: 0, available: false
        )
        let builtIn = ShellBrightness.Display(
            id: "58B598B8-49E1-4329-8987-676E26B5A4AC", name: "Built-in", value: 60, available: true
        )
        let studio = ShellBrightness.Display(
            id: "059A7397-08E6-4338-B4CB-316F43D1A11A", name: "Studio", value: 0, available: true
        )
        widget.set("brightness") {
            ShellBrightness(mainDisplayId: external.id, displays: [external, builtIn, studio]).write(into: &$0)
        }
        let controls = sliders(widget)
        XCTAssertEqual(controls.map(\.content.value), [600, 0])
        XCTAssertEqual(controls.map { widget.text.string($0.content.help) }, ["Built-in", "Studio"])
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("External"))
        let first = try XCTUnwrap(controls.first).content.action
        let last = try XCTUnwrap(controls.last).content.action
        let changed = ShellEvent(value: 0.37, phase: .changed, kind: .slider)
        XCTAssertEqual(widget.invoke(first, view: OMNI_VIEW_POPOUT, event: changed), [])
        XCTAssertEqual(sliders(widget).map(\.content.value), [370, 0])
        let cancelled = ShellEvent(phase: .cancelled, kind: .slider)
        XCTAssertEqual(widget.invoke(first, view: OMNI_VIEW_POPOUT, event: cancelled), [])
        XCTAssertEqual(sliders(widget).map(\.content.value), [600, 0])
        let ended = ShellEvent(value: 0.37, phase: .ended, kind: .slider)
        XCTAssertEqual(
            widget.invoke(first, view: OMNI_VIEW_POPOUT, event: ended), ["brightness display \(builtIn.id) set 37"]
        )
        let zero = ShellEvent(value: 0, phase: .ended, kind: .slider)
        XCTAssertEqual(
            widget.invoke(last, view: OMNI_VIEW_POPOUT, event: zero), ["brightness display \(studio.id) set 0"]
        )
    }

    func testDisplaysUsesLegacyMainBrightnessWhenMainHasNoNamedRow() throws {
        let widget = try makeWidget()
        let main = ShellBrightness.Display(
            id: "58B598B8-49E1-4329-8987-676E26B5A4AC", name: "Built-in", value: 25, available: true
        )
        let secondary = ShellBrightness.Display(
            id: "059A7397-08E6-4338-B4CB-316F43D1A11A", name: "Studio", value: 65, available: true
        )
        let ended = ShellEvent(value: 0.37, phase: .ended, kind: .slider)
        for displays in [[], [secondary]] {
            widget.set("brightness") {
                ShellBrightness(value: 25, available: true, displays: displays).write(into: &$0)
            }
            let controls = sliders(widget)
            XCTAssertEqual(controls.map(\.content.value), [250] + displays.map { UInt32($0.value * 10) })
            let legacy = try XCTUnwrap(controls.first).content
            XCTAssertEqual(widget.text.string(legacy.help), ShellLocalizer.string("Main Display", []))
            XCTAssertEqual(widget.invoke(legacy.action, view: OMNI_VIEW_POPOUT, event: ended), ["brightness set 37"])
        }
        widget.set("brightness") {
            ShellBrightness(value: 25, available: true, mainDisplayId: main.id, displays: [main, secondary])
                .write(into: &$0)
        }
        XCTAssertEqual(sliders(widget).map { widget.text.string($0.content.help) }, [main.name, secondary.name])
    }

    func testDisplaysNightShiftShowsAvailabilityAndUsesExplicitNativeCommands() throws {
        let widget = try makeWidget()
        for (enabled, status, expected) in [(false, "Off", "night-shift on"), (true, "On", "night-shift off")] {
            widget.set("nightShift") { ShellNightShift(available: true, enabled: enabled).write(into: &$0) }
            XCTAssertEqual(commands(widget).filter { $0.hasPrefix("night-shift ") }, [expected])
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(status, [])))
        }
        widget.set("nightShift") { ShellNightShift().write(into: &$0) }
        XCTAssertFalse(commands(widget).contains { $0.hasPrefix("night-shift ") })
    }

    func testDisplaysKeepsLongBrightnessListsScrollable() throws {
        let widget = try makeWidget()
        let displays = (1 ... 12).map { number in
            ShellBrightness.Display(id: UUID().uuidString, name: "Display \(number)", value: 50, available: true)
        }
        widget.set("brightness") { ShellBrightness(displays: displays).write(into: &$0) }
        let tree = widget.renderPopout()
        let scroll = try XCTUnwrap(tree.first { $0.content.scrolls })
        XCTAssertEqual(scroll.layout.height, 240)
        XCTAssertEqual(tree.filter { $0.kind == .slider }.count, displays.count)
        XCTAssertTrue(commands(widget).contains("brightness settings"))
    }

    private func makeWidget(tab: String = "displays") throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget("control-center")
        widget.set("settings") { ShellServiceValue.object(["tab": .text(tab)]).write(to: &$0) }
        widget.render(ShellBarData())
        return widget
    }

    private func renderDependencies(_ widget: ShellRenderedWidget) -> UInt64 {
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(widget.instance, OMNI_VIEW_POPOUT, 100_000_000, &stats, &error, error.count),
            OMNI_OK
        )
        return stats.deps
    }

    private func sliders(_ widget: ShellRenderedWidget) -> [TreeNode] {
        widget.renderPopout().filter { $0.kind == .slider }
    }

    private func commands(_ widget: ShellRenderedWidget) -> [String] {
        widget.renderPopout().map { widget.text.string($0.content.action) }
    }
}
