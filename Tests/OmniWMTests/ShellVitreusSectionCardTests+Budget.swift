// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
extension ShellVitreusSectionCardTests {
    private func budgetSource(_ source: ShellWidgetSource) -> ShellWidgetSource {
        let main = source.main + """

        local original = trigger
        function trigger(ctx,event)
            if event.name ~= 'test-spread' then original(ctx,event) return end
            ctx.state.windows = {}
            for _, id in {'calendar','controls','player'} do
                ctx.state.windows[id] = {location='edge',side='left',rect={x=0,y=200},glass='drawer-'..id}
            end
            local cards = require('../lib/vitreus/cards')
            for _, id in {'calendar-month','calendar-events','controls-toggles','controls-sliders',
                'controls-mixer','player-album','player-windows','page-pad','page-focus'} do
                local item = cards.record(ctx,id)
                item.location,item.side,item.rect,item.initialized = 'edge','left',{x=0,y=200},true
            end
            for _, component in ctx.data.components or {} do
                if component.widget == 'desk-pad' or component.widget == 'desk-focus' then
                    local item = cards.record(ctx,'page-'..component.id)
                    item.location,item.side,item.rect,item.initialized = 'edge','left',{x=0,y=200},true
                end
            end
            ctx.state.controlsMixer,ctx.state.expanded = true,true
            if event.value == 'calendar' then ctx.state.windows.calendar.held = true
            else cards.record(ctx,event.value).held = true end
        end
        """
        return ShellWidgetSource(
            chunk: source.chunk, main: main, modules: source.modules, isIslandRoot: true,
            moduleLimit: source.moduleLimit, components: source.components,
            componentDescriptors: source.componentDescriptors, fontFolders: source.fontFolders
        )
    }

    private func budgetFixture(
        _ shell: URL,
        extraPage: Bool = false,
        components given: [ShellComponentInstance]? = nil
    ) throws -> ShellVitreusDrawerTests.Fixture {
        let components = given ?? (ShellVitreusDockTests.components + (extraPage ? [ShellComponentInstance(
            id: "extra-pad",
            widget: "desk-pad"
        )] : []))
        let source = try VitreusFixture.source(shell, components: components)
        let widget = try ShellRenderedWidget(source: budgetSource(source), resources: VitreusFixture.resources(shell))
        let fixture = ShellVitreusDrawerTests.Fixture(
            widget: widget, monitor: VitreusFixture.monitor(), clock: .init(), scene: widget.surface.scene
        )
        windows.seed(widget)
        let catalog = try ShellComponentCatalog.catalogBytes(ShellComponentCatalog.installed(
            directories: VitreusFixture.config(shell).directories
        ))
        XCTAssertEqual(catalog.withUnsafeBufferPointer {
            omni_instance_set_value(widget.instance, "catalog", $0.baseAddress, $0.count)
        }, OMNI_OK)
        widget.set("brightness") { ShellBrightness(value: 60, available: true).write(into: &$0) }
        widget.set("microphone") { ShellMicrophone(volume: 50, muted: false).write(into: &$0) }
        widget.set("audioApps") {
            ShellAudioApps(access: .granted, apps: (0 ..< 6).map {
                .init(id: "app-\($0)", name: "Playing application \($0)", playing: true, volume: 70, muted: false)
            }).write(into: &$0)
        }
        VitreusFixture.settings(widget, [
            "pins": .strings([ShellVitreusDockTests.safari]), "addons": .strings(["notes"])
        ])
        seedBudgetCalendar(widget)
        return fixture
    }

    private func seedBudgetCalendar(_ widget: ShellRenderedWidget) {
        widget.set("calendar") {
            ShellCalendar(access: "full", month: .init(
                title: "October 2026", year: 2026, month: 10, days: 31, offset: 3, today: 28,
                weekdays: ["M", "T", "W", "T", "F", "S", "S"], marked: [5, 28]
            ), selectedDay: "2026-10-28", reminders: .init(access: "full", items: (0 ..< 3).map {
                .init(
                    id: "reminder-\($0)",
                    title: "A reminder to keep while floating",
                    list: "Personal",
                    color: "#FFFFFF",
                    due: 1_793_210_400,
                    allDay: false,
                    priority: 0,
                    canComplete: true
                )
            }, total: 3)).write(into: &$0)
        }
    }

    private func showBudgetWindows(_ fixture: ShellVitreusDrawerTests.Fixture) {
        var bar = VitreusFixture.bar(fixture.monitor)
        bar.workspaces = [.init(id: "1", name: "1", focused: true, windows: [.init(
            id: "app", bundle: "test.app", name: "App", focused: true, count: 12, hidden: 0,
            windows: (0 ..< 12)
                .map { .init(id: "window-\($0)", title: "Document \($0)", focused: $0 == 0, hidden: false) }
        )])]
        fixture.widget.render(bar)
    }

    private func assertExtraPagePlates(_ fixture: ShellVitreusDrawerTests.Fixture) {
        for id in [
            "calendar-month",
            "calendar-events",
            "controls-toggles",
            "controls-sliders",
            "controls-mixer",
            "player-windows",
            "page-pad",
            "page-focus",
            "page-extra-pad"
        ] {
            XCTAssertTrue(windows.has(fixture, "drawer-content-" + id), id)
            XCTAssertTrue(windows.has(fixture, "card-glass-" + id), id)
        }
        XCTAssertTrue(windows.has(fixture, "media-card"))
    }

    func testEverySectionAndAnExtraUserPageOutReserveAllPlatesBeforeDecorativePieces() throws {
        for held in ["calendar", "calendar-month", "player-album"] {
            let shell = try windows.docks.shell()
            defer { VitreusFixture.remove(shell) }
            let fixture = try budgetFixture(shell, extraPage: true)
            let widget = fixture.widget
            windows.shelfOpen = true
            windows.show(fixture)
            try windows.invoke(fixture, "addon-pin-notes")
            VitreusFixture.trigger(widget.instance, "test-spread", held)
            showBudgetWindows(fixture)
            let surface = widget.surface
            XCTAssertEqual(surface.manipulationTargets.count, 17)
            let layout = surface.layout
            let elements = layout.core.elements { _ in true }
            let bodies = elements.filter { layout.core.kind(of: $0) == .glass }
            let counts = bodies.map { body in elements.count { layout.core.parent(of: $0) == body } }
            let body = try VitreusFixture.element(widget, key: "bar")
            XCTAssertEqual(elements.count { layout.core.parent(of: $0) == body }, held == "player-album" ? 38 : 64)
            let deskBody = try VitreusFixture.element(widget, key: "desk-glass")
            XCTAssertEqual(elements.count { layout.core.parent(of: $0) == deskBody }, held == "player-album" ? 36 : 10)
            XCTAssertTrue(counts.allSatisfy { $0 <= 64 })
            assertExtraPagePlates(fixture)
            XCTAssertEqual(layout.core.parent(of: try VitreusFixture.element(widget, key: "window-shelf-glass")), body)
            XCTAssertEqual(
                layout.core.parent(of: try VitreusFixture.element(widget, key: "card-glass-calendar-month")),
                body
            )
            XCTAssertFalse(surface.islandRegions().contains { $0.contains(CGPoint(x: 960, y: 1000)) })
            var stats = omni_render_stats()
            var error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(omni_instance_render(
                widget.instance, OMNI_VIEW_BAR, ShellWidgetPackage.renderBudget, &stats, &error, error.count
            ), OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            print(
                "SECTION-BUDGET held=\(held) targets=\(surface.manipulationTargets.count) shapes=\(counts) cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)"
            )
        }
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testThreeStoredPanelsAndThePageCardsStayWithinTheRenderBudget() throws {
        let shell = try windows.docks.shell()
        defer { VitreusFixture.remove(shell) }
        let fixture = try budgetFixture(shell, extraPage: true)
        windows.shelfOpen = true
        windows.show(fixture)
        for id in ["calendar", "controls", "player"] {
            windows.trigger(fixture, "drawer-" + id)
            try windows.store(fixture, id: id)
        }
        for id in ["calendar", "controls", "player"] {
            XCTAssertTrue(windows.has(fixture, "drawer-content-" + id))
        }
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(omni_instance_render(
            fixture.widget.instance, OMNI_VIEW_BAR, ShellWidgetPackage.renderBudget, &stats, &error, error.count
        ), OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        print("SHELVED-PANELS cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)")
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testPageCapacityKeepsTwentyFourTargetsAndOverflowPagesStayInTheDesk() throws {
        let shell = try windows.docks.shell()
        defer { VitreusFixture.remove(shell) }
        let components = ShellVitreusDockTests.components + (0 ..< 9).map {
            ShellComponentInstance(id: "pad-\($0)", widget: "desk-pad")
        }
        let fixture = try budgetFixture(shell, components: components)
        windows.shelfOpen = true
        windows.show(fixture)
        try windows.invoke(fixture, "addon-pin-notes")
        VitreusFixture.trigger(fixture.widget.instance, "test-spread", "calendar-month")
        showBudgetWindows(fixture)
        XCTAssertEqual(fixture.widget.surface.manipulationTargets.count, 24)
        XCTAssertFalse(windows.has(fixture, "drawer-content-page-pad-8"))
        _ = try windows.invoke(fixture, "tab-pad-8")
        let page = try VitreusFixture.element(fixture.widget, key: "pad-8")
        let desk = try XCTUnwrap(fixture.widget.surface.manipulationTargets.keys.first {
            fixture.widget.surface.layout.core.key(of: $0) == VitreusFixture.key("desk")
        })
        XCTAssertTrue(fixture.widget.surface.isWithin(page, desk))
        XCTAssertEqual(fixture.widget.surface.layout.core.elements { _ in true }.count {
            fixture.widget.surface.layout.core.key(of: $0) == VitreusFixture.key("pad-8")
        }, 1)
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(omni_instance_render(
            fixture.widget.instance, OMNI_VIEW_BAR, ShellWidgetPackage.renderBudget, &stats, &error, error.count
        ), OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        let layout = fixture.widget.surface.layout
        let elements = layout.core.elements { _ in true }
        let counts = elements.filter { layout.core.kind(of: $0) == .glass }.map { body in
            elements.count { layout.core.parent(of: $0) == body }
        }
        XCTAssertTrue(counts.allSatisfy { $0 <= 64 })
        print(
            "CAPACITY-BUDGET targets=\(fixture.widget.surface.manipulationTargets.count) shapes=\(counts) cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)"
        )
    }
}
