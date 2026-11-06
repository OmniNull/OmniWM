// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
extension ShellVitreusSectionCardTests {
    private static let budgetWindows = ["calendar", "controls", "player"]
    private static let budgetSections = [
        "calendar-month", "calendar-events", "controls-toggles", "controls-sliders",
        "controls-mixer", "player-album", "player-windows"
    ]
    private static let budgetComponents = ShellVitreusDockTests.components + [
        ShellComponentInstance(id: "extra-pad", widget: "desk-pad")
    ]
    private static let movingPieces = [
        "lip", "bulge", "ripple-break-top", "ripple-break-bottom", "stray",
        "ripple-return-top", "ripple-return-bottom"
    ]

    private func budgetPageIDs(_ components: [ShellComponentInstance]) -> [String] {
        components.filter { $0.enabled && ($0.widget == "desk-pad" || $0.widget == "desk-focus") }.map(\.id)
    }

    private func budgetPlateIDs(_ pages: [String]) -> [String] {
        Self.budgetSections.filter { $0 != "player-album" } + pages.map { "page-" + $0 }
    }

    private func budgetEdgeKeys(_ prefix: String, held: Bool) -> [String] {
        let sides = held ? ["left", "right", "top", "bottom"] : ["left"]
        let pieces = held ? Self.movingPieces : ["lip", "bulge"]
        return sides.flatMap { side in
            pieces.map { prefix + (side == "right" ? "" : "-" + side) + "-" + $0 }
        }
    }

    private func assertBudgetTargets(_ fixture: ShellVitreusDrawerTests.Fixture, pages: [String]) {
        let names = (Self.budgetWindows + budgetPlateIDs(pages)).map { "drawer-content-" + $0 }
            + ["media-card", "desk", "addon-drawer", "dock-pill", "addon-pill"]
        let surface = fixture.widget.surface
        XCTAssertEqual(surface.manipulationTargets.count, names.count)
        XCTAssertEqual(
            Set(surface.manipulationTargets.keys.map { surface.layout.core.key(of: $0) }),
            Set(names.map { VitreusFixture.key($0) })
        )
    }

    private func budgetSource(_ source: ShellWidgetSource) -> ShellWidgetSource {
        let main = source.main + """

        local original = trigger
        function trigger(ctx,event)
            if event.name ~= 'test-spread' then original(ctx,event) return end
            ctx.state.windows = {}
            for _, id in {\(Self.budgetWindows.map { "'\($0)'" }.joined(separator: ","))} do
                ctx.state.windows[id] = {location='edge',side='left',rect={x=0,y=200},glass='drawer-'..id}
            end
            local cards = require('../lib/vitreus/cards')
            for _, id in {\(Self.budgetSections.map { "'\($0)'" }.joined(separator: ","))} do
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
        components given: [ShellComponentInstance]? = nil
    ) throws -> ShellVitreusDrawerTests.Fixture {
        let components = given ?? Self.budgetComponents
        let source = try VitreusFixture.source(shell, components: components)
        let widget = try ShellRenderedWidget(
            source: budgetSource(source), resources: VitreusFixture.resources(shell),
            renderBudget: ShellRenderTestBudget.unlimited
        )
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
        for id in budgetPlateIDs(budgetPageIDs(Self.budgetComponents)) {
            XCTAssertTrue(windows.has(fixture, "drawer-content-" + id), id)
            XCTAssertTrue(windows.has(fixture, "card-glass-" + id), id)
        }
        XCTAssertTrue(windows.has(fixture, "media-card"))
    }

    func testEverySectionAndAnExtraUserPageOutReserveAllPlatesBeforeDecorativePieces() throws {
        try checkEverySectionAndAnExtraPage(renderBudget: ShellRenderTestBudget.unlimited)
    }

    #if OMNIWM_LIVE_CHECKS
        func testRenderSpeedEverySectionAndAnExtraPageStayWithinProductionBudget() throws {
            try checkEverySectionAndAnExtraPage(renderBudget: ShellWidgetPackage.renderBudget)
        }
    #endif

    private func checkEverySectionAndAnExtraPage(renderBudget: UInt64) throws {
        let pages = budgetPageIDs(Self.budgetComponents)
        let cardIDs = budgetPlateIDs(pages)
        for held in ["calendar", "calendar-month", "player-album"] {
            let shell = try windows.docks.shell()
            defer { VitreusFixture.remove(shell) }
            let fixture = try budgetFixture(shell)
            let widget = fixture.widget
            windows.shelfOpen = true
            windows.show(fixture)
            try windows.invoke(fixture, "addon-pin-notes")
            VitreusFixture.trigger(widget.instance, "test-spread", held)
            showBudgetWindows(fixture)
            let surface = widget.surface
            assertBudgetTargets(fixture, pages: pages)
            let layout = surface.layout
            let elements = layout.core.elements { _ in true }
            let bodies = elements.filter { layout.core.kind(of: $0) == .glass }
            let counts = bodies.map { body in elements.count { layout.core.parent(of: $0) == body } }
            let barShapes = ["shell", "window-shelf-glass"]
                + Self.budgetWindows.map { "drawer-" + $0 }
                + cardIDs.map { "card-glass-" + $0 }
                + Self.budgetWindows.flatMap { budgetEdgeKeys($0 + "-window", held: held == $0) }
                + cardIDs.flatMap { budgetEdgeKeys($0 + "-card", held: held == $0) }
            let deskShapes = ["desk-shape", "media-card-glass"]
                + Self.movingPieces.filter { $0 != "lip" }.map { "desk-" + $0 }
                + budgetEdgeKeys("player-album-card", held: held == "player-album")
            for (name, expected) in [("bar", barShapes), ("desk-glass", deskShapes)] {
                let parent = try VitreusFixture.element(widget, key: name)
                let children = elements.filter { layout.core.parent(of: $0) == parent }
                XCTAssertEqual(children.count, expected.count, name)
                XCTAssertEqual(
                    Set(children.map { layout.core.key(of: $0) }),
                    Set(expected.map { VitreusFixture.key($0) }),
                    name
                )
            }
            let body = try VitreusFixture.element(widget, key: "bar")
            XCTAssertTrue(counts.allSatisfy { $0 <= Int(OMNI_GLASS_SHAPE_LIMIT) })
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
                widget.instance, OMNI_VIEW_BAR, renderBudget, &stats, &error, error.count
            ), OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            print(
                "SECTION-BUDGET held=\(held) targets=\(surface.manipulationTargets.count) shapes=\(counts) cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)"
            )
        }
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testThreeStoredPanelsAndThePageCardsRemainVisible() throws {
        try checkStoredPanelsAndPageCards(renderBudget: ShellRenderTestBudget.unlimited)
    }

    #if OMNIWM_LIVE_CHECKS
        func testRenderSpeedStoredPanelsAndPageCardsStayWithinProductionBudget() throws {
            try checkStoredPanelsAndPageCards(renderBudget: ShellWidgetPackage.renderBudget)
        }
    #endif

    private func checkStoredPanelsAndPageCards(renderBudget: UInt64) throws {
        let shell = try windows.docks.shell()
        defer { VitreusFixture.remove(shell) }
        let fixture = try budgetFixture(shell)
        windows.shelfOpen = true
        windows.show(fixture)
        for id in Self.budgetWindows {
            windows.trigger(fixture, "drawer-" + id)
            try windows.store(fixture, id: id)
        }
        for id in Self.budgetWindows {
            XCTAssertTrue(windows.has(fixture, "drawer-content-" + id))
        }
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(omni_instance_render(
            fixture.widget.instance, OMNI_VIEW_BAR, renderBudget, &stats, &error, error.count
        ), OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        print("SHELVED-PANELS cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)")
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testPageCapacityKeepsTwentyFourTargetsAndOverflowPagesStayInTheDesk() throws {
        try checkOverflowPages(renderBudget: ShellRenderTestBudget.unlimited)
    }

    #if OMNIWM_LIVE_CHECKS
        func testRenderSpeedOverflowPagesStayWithinProductionBudget() throws {
            try checkOverflowPages(renderBudget: ShellWidgetPackage.renderBudget)
        }
    #endif

    private func checkOverflowPages(renderBudget: UInt64) throws {
        let shell = try windows.docks.shell()
        defer { VitreusFixture.remove(shell) }
        let extraPages = (0 ..< 9).map {
            ShellComponentInstance(id: "pad-\($0)", widget: "desk-pad")
        }
        let overflowPage = try XCTUnwrap(extraPages.last)
        let components = ShellVitreusDockTests.components + extraPages
        let shelfPages = budgetPageIDs(ShellVitreusDockTests.components + extraPages.dropLast())
        let fixture = try budgetFixture(shell, components: components)
        windows.shelfOpen = true
        windows.show(fixture)
        try windows.invoke(fixture, "addon-pin-notes")
        VitreusFixture.trigger(fixture.widget.instance, "test-spread", "calendar-month")
        showBudgetWindows(fixture)
        assertBudgetTargets(fixture, pages: shelfPages)
        XCTAssertFalse(windows.has(fixture, "drawer-content-page-" + overflowPage.id))
        _ = try windows.invoke(fixture, "tab-" + overflowPage.id)
        let page = try VitreusFixture.element(fixture.widget, key: overflowPage.id)
        let desk = try XCTUnwrap(fixture.widget.surface.manipulationTargets.keys.first {
            fixture.widget.surface.layout.core.key(of: $0) == VitreusFixture.key("desk")
        })
        XCTAssertTrue(fixture.widget.surface.isWithin(page, desk))
        XCTAssertEqual(fixture.widget.surface.layout.core.elements { _ in true }.count {
            fixture.widget.surface.layout.core.key(of: $0) == VitreusFixture.key(overflowPage.id)
        }, 1)
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(omni_instance_render(
            fixture.widget.instance, OMNI_VIEW_BAR, renderBudget, &stats, &error, error.count
        ), OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        let layout = fixture.widget.surface.layout
        let elements = layout.core.elements { _ in true }
        let counts = elements.filter { layout.core.kind(of: $0) == .glass }.map { body in
            elements.count { layout.core.parent(of: $0) == body }
        }
        XCTAssertTrue(counts.allSatisfy { $0 <= Int(OMNI_GLASS_SHAPE_LIMIT) })
        print(
            "CAPACITY-BUDGET targets=\(fixture.widget.surface.manipulationTargets.count) shapes=\(counts) cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)"
        )
    }
}
