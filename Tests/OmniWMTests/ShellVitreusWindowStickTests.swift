// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusWindowStickTests: XCTestCase {
    typealias Fixture = ShellVitreusDrawerTests.Fixture
    let windows = ShellVitreusWindowShelfTests()
    let sides: [(String, ShellMorphRecipe.SourceEdge)] = [
        ("left", .left), ("right", .right), ("top", .top), ("bottom", .bottom)
    ]

    func key(_ id: String, _ side: String, _ piece: String) -> String {
        id + "-window" + (side == "right" ? "" : "-" + side) + "-" + piece
    }

    func placement(_ side: String, size: CGSize) -> CGPoint {
        switch side {
        case "left": CGPoint(x: 20, y: 250)
        case "right": CGPoint(x: 1920 - size.width - 20, y: 250)
        case "top": CGPoint(x: 100, y: 45)
        default: CGPoint(x: 150, y: 1080 - size.height - 20)
        }
    }

    func stuck(_ fixture: Fixture, id: String, side: String) throws -> CGRect {
        windows.trigger(fixture, "drawer-" + id)
        let home = try windows.frame(fixture, "drawer-content-" + id)
        try windows.move(fixture, id: id, to: placement(side, size: home.size))
        return try windows.frame(fixture, "drawer-content-" + id)
    }

    func assertFlush(_ rect: CGRect, side: String) {
        switch side {
        case "left": XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        case "right": XCTAssertEqual(rect.maxX, 1920, accuracy: 0.001)
        case "top": XCTAssertEqual(rect.minY, 32, accuracy: 0.001)
        default: XCTAssertEqual(rect.maxY, 1080, accuracy: 0.001)
        }
    }

    func rendered(_ fixture: Fixture, _ key: String) throws -> CGRect {
        let element = try VitreusFixture.element(fixture.widget, key: key)
        return try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.scene.shapeTracks.entries[element.slot]).shape(at: .infinity).rect
        }
    }

    func assertPieces(
        _ fixture: Fixture,
        id: String,
        side: String,
        edge: ShellMorphRecipe.SourceEdge,
        held: Bool = false
    ) throws {
        let lip = key(id, side, "lip"), bulge = key(id, side, "bulge")
        let source = try XCTUnwrap(windows.drawers.morph(fixture, lip).source)
        XCTAssertEqual(source.target, VitreusFixture.key("drawer-content-" + id))
        XCTAssertEqual(source.edge, edge)
        XCTAssertTrue(source.contact)
        XCTAssertNil(source.pads)
        let handle = try VitreusFixture.element(fixture.widget, key: lip)
        let content = fixture.widget.surface.layout.core.content(of: handle)
        XCTAssertFalse(content.glassHit)
        XCTAssertEqual(content.glassShape, 0)
        XCTAssertEqual(try windows.drawers.morph(fixture, bulge).source, source)
        let recipe = try windows.drawers.morph(fixture, lip)
        XCTAssertEqual(side == "left" || side == "right" ? recipe.stop(at: 0).height : recipe.stop(at: 0).width, 1)
        XCTAssertEqual(
            side == "left" || side == "right" ? recipe.stop(at: 0.625).height : recipe.stop(at: 0.625).width,
            0
        )
        for piece in ["ripple-break-top", "ripple-break-bottom", "stray", "ripple-return-top", "ripple-return-bottom"] {
            if held {
                let trigger = try XCTUnwrap(windows.drawers.morph(fixture, key(id, side, piece)).trigger)
                XCTAssertEqual(trigger.shape, VitreusFixture.key(bulge))
                XCTAssertTrue(trigger.contact)
            } else { XCTAssertFalse(windows.has(fixture, key(id, side, piece))) }
        }
    }

    func testEveryDropDownSticksOnEverySideWithOnlyItsOwnLipAndBindings() throws {
        for id in ["calendar", "controls", "player"] {
            for (side, edge) in sides {
                let fixture = try windows.fixture()
                let shown = try stuck(fixture, id: id, side: side)
                assertFlush(shown, side: side)
                let plate = try XCTUnwrap(windows.drawers.morph(fixture, "drawer").source)
                XCTAssertEqual(plate.edge, edge)
                XCTAssertNotNil(plate.pads)
                for (_, other) in sides where other != edge { XCTAssertNotNil(plate.adhere.from(other)) }
                try assertPieces(fixture, id: id, side: side, edge: edge)
                for (other, _) in sides where other != side {
                    XCTAssertFalse(windows.has(fixture, key(id, other, "lip")))
                }
                let lip = try rendered(fixture, key(id, side, "lip"))
                XCTAssertGreaterThan(side == "left" || side == "right" ? lip.height : lip.width, 0)
            }
        }
    }

    func testPullingOffEachSideRetractsTheLipWithoutPerSampleLuau() throws {
        for (side, _) in sides {
            let fixture = try windows.fixture()
            let shown = try stuck(fixture, id: "calendar", side: side)
            var end = shown.origin
            switch side {
            case "left": end.x += 130
            case "right": end.x -= 130
            case "top": end.y += 130
            default: end.y -= 130
            }
            var pointer = try windows.grab(fixture, id: "calendar", to: end)
            for (other, edge) in sides { try assertPieces(fixture, id: "calendar", side: other, edge: edge, held: true)
            }
            let output = fixture.widget.output()
            let previous = fixture.widget.surface.manipulation?.preview
            switch side {
            case "left": pointer.x += 20
            case "right": pointer.x -= 20
            case "top": pointer.y += 20
            default: pointer.y -= 20
            }
            fixture.widget.surface.drag(to: pointer, screen: .zero, timestamp: 0.02)
            XCTAssertNotEqual(fixture.widget.surface.manipulation?.preview, previous)
            XCTAssertEqual(fixture.widget.output(), output)
            let lip = try rendered(fixture, key("calendar", side, "lip"))
            XCTAssertEqual(side == "left" || side == "right" ? lip.height : lip.width, 0, accuracy: 0.001)
            windows.drop(fixture, at: pointer)
            for (other, _) in sides { XCTAssertFalse(windows.has(fixture, key("calendar", other, "lip"))) }
        }
    }

    func testCornerHysteresisKeepsTheCurrentSideUntilAnotherIsClearlyCloser() throws {
        let fixture = try windows.fixture()
        _ = try stuck(fixture, id: "calendar", side: "left")
        try windows.move(fixture, id: "calendar", to: CGPoint(x: 20, y: 42))
        assertFlush(try windows.frame(fixture, "drawer-content-calendar"), side: "left")
        XCTAssertTrue(windows.has(fixture, key("calendar", "left", "lip")))
        try windows.move(fixture, id: "calendar", to: CGPoint(x: 50, y: 32))
        assertFlush(try windows.frame(fixture, "drawer-content-calendar"), side: "top")
        XCTAssertTrue(windows.has(fixture, key("calendar", "top", "lip")))
        XCTAssertFalse(windows.has(fixture, key("calendar", "left", "lip")))
    }
}

@MainActor
extension ShellVitreusWindowStickTests {
    func testNearestSideAndSnapClampAtTheSharedGeometryOwner() throws {
        let shell = try VitreusFixture.shell()
        defer { VitreusFixture.remove(shell) }
        let probe = try VitreusFixture.probe(shell, """
        local stick = require('../lib/vitreus/stick')
        function render(ctx)
            local room = {x=0,y=32,w=1000,h=768}
            local function side(x,y,current)
                return stick.nearest({x=x,y=y,w=300,h=200},room,current,60) or 'nil'
            end
            local values = { 'tie='..side(40,72,nil), 'keep='..side(30,72,'top'),
                'switch='..side(5,82,'top'), 'out='..side(200,200,'left') }
            for _, edge in stick.sides do
                local p = stick.snap({x=999,y=999,w=300,h=200},room,edge)
                values[#values+1] = edge..'='..p.x..','..p.y
            end
            local tree={w=400,h=400}
            for _, text in values do tree[#tree+1]=ui.text{text=text} end
            return ui.column(tree)
        end
        """)
        probe.render(VitreusFixture.bar())
        XCTAssertEqual(Set(probe.strings()), [
            "tie=left",
            "keep=top",
            "switch=left",
            "out=nil",
            "left=0,600",
            "right=700,600",
            "top=700,32",
            "bottom=700,600"
        ])
    }

    func testHeldWindowAndTwoStuckWindowsKeepFifteenTargetsAndStayUnderShapeAndRenderBudgets() throws {
        let widget = try windows.docks.island([
            "pins": .strings([ShellVitreusDockTests.safari]),
            "addons": .strings(["notes"])
        ])
        let fixture = Fixture(
            widget: widget,
            monitor: VitreusFixture.monitor(),
            clock: .init(),
            scene: widget.surface.scene
        )
        windows.seed(widget)
        windows.show(fixture)
        _ = try stuck(fixture, id: "calendar", side: "left")
        _ = try stuck(fixture, id: "controls", side: "right")
        _ = try stuck(fixture, id: "player", side: "bottom")
        windows.trigger(fixture, "desk-open")
        try windows.invoke(fixture, "addon-pin-notes")
        windows.shelfOpen = true
        windows.show(fixture)
        let pointer = try windows.grab(fixture, id: "calendar", to: CGPoint(x: 130, y: 300))
        XCTAssertEqual(widget.surface.manipulationTargets.count, 15)
        let layout = widget.surface.layout
        let elements = layout.core.elements { _ in true }
        let counts = elements.filter { layout.core.kind(of: $0) == .glass }.map { body in
            elements.count { layout.core.parent(of: $0) == body }
        }
        XCTAssertEqual(counts.max(), 37)
        XCTAssertTrue(counts.allSatisfy { $0 <= 64 })
        XCTAssertFalse(widget.surface.islandRegions().contains { $0.contains(CGPoint(x: 10, y: 900)) })
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(
                widget.instance,
                OMNI_VIEW_BAR,
                ShellWidgetPackage.renderBudget,
                &stats,
                &error,
                error.count
            ),
            OMNI_OK,
            String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        print(
            "FOUR-EDGE-BUDGET targets=\(widget.surface.manipulationTargets.count) shapes=\(counts) cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)"
        )
        windows.drop(fixture, at: pointer)
    }
}
