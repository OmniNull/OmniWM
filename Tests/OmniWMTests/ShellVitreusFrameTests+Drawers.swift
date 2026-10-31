// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusFrameDrawerTests: XCTestCase {
    private let cu = 1.5525

    private func fixture(_ edge: String) throws -> ShellRenderedWidget {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let source = try VitreusFixture.source(shell)
        let shim = "local clock=require('./frame-clock') local os={clock=function() return clock.now end,date=os.date}\n"
        let modules = source.modules.map { module in
            module.path.hasSuffix("lib/vitreus/drawer.luau")
                ? ShellWidgetSource.Module(path: module.path, source: shim + module.source) : module
        } + [.init(path: "vitreus/lib/vitreus/frame-clock.luau", source: "return {now=0}")]
        let widget = try ShellRenderedWidget(
            name: "frame-drawer-probe", source: """
            local drawer = require('../lib/vitreus/drawer')
            local clock = require('../lib/vitreus/frame-clock')
            function trigger(ctx,event)
                if event.name=='probe-clock' then clock.now=tonumber(event.value) else drawer.trigger(ctx,event) end
            end
            function render(ctx)
                local edge=ctx.data.settings.layout
                local vertical=edge=='left' or edge=='right'
                local strip={x=if edge=='right' then 1857.9 else 0,y=if edge=='fbottom' then 1017.9 else 0,
                    w=if vertical then 62.1 else 1920,h=if vertical then 1080 else 62.1,
                    cx=if vertical then (if edge=='right' then 1888.95 else 31.05) else 960,
                    cy=if vertical then 540 else (if edge=='fbottom' then 1048.95 else 31.05)}
                strip.slots={controls={cx=if vertical then strip.cx else 1800,cy=if vertical then 930 else strip.cy},
                    clock={cx=if vertical then strip.cx else 1710,cy=if vertical then 1000 else strip.cy},
                    title={cx=960,cy=540}}
                local g={frame={edge=edge,vertical=vertical,strip=strip,thickness=10.8},pill=strip,
                    layout=edge,size={w=1920,h=1080},k={bcu=1.5525,u=1.35},calm={response=.513,bounce=.06}}
                local items={w=1920,h=1080,align='topLeading'}
                local body={key='bar',w=1920,h=1080,fill='#22334455',blend=35.1}
                for _,shape in drawer.shapes(ctx,g) or {} do body[#body+1]=shape end
                if #body>0 then items[#items+1]=ui.glass(body) end
                local panel=drawer.geometry(ctx,g)
                if panel then
                    items[#items+1]=ui.text{text=string.format('P|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f|%.9f',
                        panel.x,panel.y,panel.w,panel.h,panel.bodyX,panel.bodyY,panel.bodyW,panel.bodyH,panel.originX,panel.originY,panel.slideX,panel.slideY,panel.delay)}
                end
                return ui.stack(items)
            end
            """, modules: modules, chunk: source.chunk,
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders),
            memoryLimit: ShellWidgetPackage.memoryLimit, moduleLimit: source.moduleLimit
        )
        VitreusFixture.settings(widget, ["layout": .string(edge)])
        widget.set("seconds") { $0.number(2000) }
        widget.set("brightness") { ShellBrightness(value: 50, available: true).write(into: &$0) }
        widget.render(VitreusFixture.bar())
        return widget
    }

    private func open(_ widget: ShellRenderedWidget, _ name: String) {
        VitreusFixture.trigger(widget.instance, "drawer-" + name, VitreusFixture.bar().monitorId)
        widget.render(VitreusFixture.bar())
    }

    private func time(_ widget: ShellRenderedWidget, _ time: Double) {
        VitreusFixture.trigger(widget.instance, "probe-clock", String(time))
    }

    private func values(_ widget: ShellRenderedWidget) throws -> [Double] {
        let text = try XCTUnwrap(widget.strings().first { $0.hasPrefix("P|") })
        let values = text.split(separator: "|").dropFirst().compactMap { Double($0) }
        XCTAssertEqual(values.count, 13)
        return values
    }

    private func recipe(_ widget: ShellRenderedWidget, _ key: String) throws -> ShellMorphRecipe {
        let element = try VitreusFixture.element(widget, key: key)
        let paint = widget.surface.layout.core.paint(of: element)
        return try XCTUnwrap(ShellMorphRecipe(widget.text.string(paint.morph)))
    }
}

extension ShellVitreusFrameDrawerTests {
    func testSideDrawersStartAtTheStripLineAndOnlyControlsSlideFromTheirButton() throws {
        for edge in ["left", "right"] {
            for name in ["controls", "calendar", "player"] {
                let widget = try fixture(edge)
                open(widget, name)
                let panel = try values(widget)
                let line = edge == "left" ? 31.05 : 1888.95
                XCTAssertEqual(edge == "left" ? panel[4] : panel[4] + panel[6], line, accuracy: 0.001)
                XCTAssertEqual(edge == "left" ? panel[0] : 1920 - panel[0] - panel[2], 62.1 + 6.5 * cu, accuracy: 0.001)
                XCTAssertEqual(panel[8], line, accuracy: 0.001)
                XCTAssertEqual(panel[10], 0)
                if name == "controls" {
                    XCTAssertGreaterThan(panel[11], 0)
                    XCTAssertEqual(panel[9] + panel[11], 930, accuracy: 0.001)
                } else { XCTAssertEqual(panel[11], 0) }
                let morph = try recipe(widget, "drawer-frame-" + name)
                XCTAssertEqual(morph.anchor.x, edge == "left" ? 0 : 1)
                XCTAssertEqual(morph.stop(at: 0).dy, panel[11], accuracy: 0.001)
                XCTAssertEqual(morph.stop(at: 1).dy, 0, accuracy: 0.001)
            }
        }
    }

    func testHorizontalDrawersUseTheRightEndAndKeepCalendarAndPlayerStationary() throws {
        for edge in ["ftop", "fbottom"] {
            for name in ["controls", "calendar", "player"] {
                let widget = try fixture(edge)
                open(widget, name)
                let panel = try values(widget)
                if name == "player" { XCTAssertEqual(panel[0] + panel[2] / 2, 960, accuracy: 0.001) }
                else { XCTAssertEqual(panel[0] + panel[2], 1920 - 10.8 - 6.5 * cu, accuracy: 0.001) }
                XCTAssertEqual(panel[11], 0)
                if name == "controls" {
                    XCTAssertEqual(panel[8] + panel[10], 1800, accuracy: 0.001)
                    XCTAssertNotEqual(panel[10], 0)
                } else { XCTAssertEqual(panel[10], 0) }
                let line = edge == "ftop" ? 31.05 : 1048.95
                XCTAssertEqual(edge == "ftop" ? panel[5] : panel[5] + panel[7], line, accuracy: 0.001)
                let morph = try recipe(widget, "drawer-frame-" + name)
                XCTAssertEqual(morph.anchor.y, edge == "ftop" ? 0 : 1)
                XCTAssertEqual(morph.stop(at: 0).dx, panel[10], accuracy: 0.001)
                XCTAssertEqual(morph.stop(at: 1).dx, 0, accuracy: 0.001)
            }
        }
    }

    func testFiveImpulseRecipeSurvivesTheWireAndUsesTheDeclaredSprings() throws {
        let widget = try fixture("left")
        open(widget, "controls")
        let recipe = try recipe(widget, "drawer-frame-controls")
        XCTAssertEqual(recipe.impulses.count, 5)
        XCTAssertEqual(recipe.impulses.map(\.velocity), [220, -260, -520, 300, -160])
        XCTAssertEqual(recipe.impulses.map(\.phase), [.open, .open, .open, .close, .close])
        XCTAssertTrue(recipe.impulses.allSatisfy { $0.kind == .after })
        XCTAssertEqual(recipe.impulses[0].pivot, .anchor)
        XCTAssertTrue(recipe.impulses.dropFirst().allSatisfy { $0.pivot == .centre })
        XCTAssertEqual(recipe.impulses[0].time, recipe.impulses[1].time, accuracy: 0.0001)
    }

    func testFrameSwitchDelayIsTheAnalyticDriplHalfwayCrossingWithOnlyALaterSettleTimer() throws {
        let widget = try fixture("left")
        open(widget, "controls")
        time(widget, 10)
        open(widget, "calendar")
        let panel = try values(widget)
        let frequency = 2 * Double.pi / 0.926
        let spring = ShellSpringDynamics.Parameters(
            mass: 1,
            stiffness: frequency * frequency,
            damping: 2 * (1 - 0.41) * frequency
        )
        let plan = ShellReveal(begin: 0, progress: 1, target: 0, spring: spring)
        let expected = try XCTUnwrap(plan.crossings(at: 0.5, rising: false).first)
        XCTAssertEqual(panel[12], expected, accuracy: 0.00001)
        let element = try VitreusFixture.element(widget, key: "drawer-frame-calendar")
        let reveal =
            try XCTUnwrap(ShellRevealRecipe(widget.text.string(widget.surface.layout.core.paint(of: element).reveal)))
        XCTAssertEqual(reveal.delay, expected, accuracy: 0.00001)
        var service = omni_service_request()
        var timers: [Double] = []
        while omni_vm_next_service(widget.vm, &service) {
            if service.kind == OMNI_SERVICE_TIMER, !service.cancelled { timers.append(service.seconds) }
        }
        XCTAssertEqual(timers.count, 1)
        XCTAssertTrue(timers.allSatisfy { $0 > expected })
    }

    func testRipplesUseNativeCrossingTriggersWithNoHitCoverage() throws {
        let widget = try fixture("ftop")
        open(widget, "player")
        for phase in ["open", "close"] {
            let name = "drawer-ripple-player-" + phase + "-1"
            let recipe = try recipe(widget, name)
            let trigger = try XCTUnwrap(recipe.trigger)
            XCTAssertEqual(trigger.shape, VitreusFixture.key("drawer-frame-player"))
            XCTAssertEqual(trigger.at, phase == "open" ? 0.84 : 0.06)
            XCTAssertEqual(trigger.rising, phase == "open")
            XCTAssertGreaterThan(recipe.stops.count, 2)
            XCTAssertLessThanOrEqual(recipe.stops.count, 16)
            XCTAssertEqual(recipe.stops.first?.height, 0)
            XCTAssertEqual(recipe.stops.last?.height, 0)
            let node = try VitreusFixture.element(widget, key: name)
            XCTAssertFalse(widget.surface.layout.core.content(of: node).glassHit)
        }
    }
}
