// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusVisualiserTests: XCTestCase {
    struct Fixture {
        let widget: ShellRenderedWidget
        var settings: [String: ShellComponentValue]
    }

    struct Column {
        let index: Int
        let band: Double
        let base: CGPoint
        let direction: CGVector
        let width: Double
        let radius: Double
        let taper: Double
        let rotation: Double
    }

    private let monitor = VitreusFixture.monitor(width: 1512, height: 982)

    func fixture(
        settings: [String: ShellComponentValue] = ["visualiser": .bool(true)],
        budget: Int? = nil,
        metadata: Bool = false
    ) throws -> Fixture {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let argument = budget.map(String.init) ?? "nil"
        let drawing = metadata ? """
        local plan=visualiser.plan(ctx,g,\(argument))
        local rows={}
        if plan then
            rows[#rows+1]=ui.text{text=string.format("m %d %d %d",plan.configured,plan.requested,plan.count)}
            for _,c in plan.columns do
                rows[#rows+1]=ui.text{text=string.format("c %d %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g",
                    c.index,c.band,c.baseX,c.baseY,c.dirX,c.dirY,c.w,c.radius,c.taper,c.rotation)}
            end
        end
        return ui.column(rows)
        """ : """
        local shapes=visualiser.shapes(ctx,g,\(argument)) or {}
        if #shapes==0 then return ui.stack{w=g.size.w,h=g.size.h,decorative=true} end
        local body={key="visualiser-test-body",w=g.size.w,h=g.size.h,align="topLeading",
            fill=0x45516FFF,blend=26*g.k.u,rim=0.1}
        for _,shape in shapes do body[#body+1]=shape end
        return ui.glass(body)
        """
        let widget = try VitreusFixture.probe(shell, """
        local visualiser=require("../lib/vitreus/visualiser")
        local bar=require("../lib/vitreus/bar")
        function render(ctx)
            local g=bar.geometry(ctx,ctx.data.island)
            \(drawing)
        end
        """)
        let fixture = Fixture(widget: widget, settings: settings)
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.spectrum.automatic = false
            widget.surface.scene.spectrum.bands = ShellSpectrumBands()
        }
        setBands(widget, Array(repeating: 0.5, count: 60))
        show(fixture)
        return fixture
    }

    func show(_ fixture: Fixture) {
        VitreusFixture.settings(fixture.widget, fixture.settings)
        fixture.widget.set("seconds") { $0.number(1000) }
        fixture.widget.set("island") { VitreusFixture.island(monitor).write(to: &$0) }
        fixture.widget.render(VitreusFixture.bar(monitor))
        fixture.widget.surface.view.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
    }

    func setBands(_ widget: ShellRenderedWidget, _ values: [Float], access: AppVolumeAccess = .granted) {
        widget.set("spectrum") { ShellSpectrum(access: access, bars: values).write(into: &$0) }
        let time = widget.surface.clock()
        ShellLayerScene.engineQueue.sync {
            var bands = ShellSpectrumBands.Bars(repeating: 0)
            if access == .granted {
                for index in 0 ..< min(values.count, 60) { bands[index] = values[index] }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            widget.surface.scene.spectrum.bands.store(bands)
            _ = widget.surface.scene.stepSpectrum(at: time)
            CATransaction.commit()
        }
    }

    private func dependencies(_ widget: ShellRenderedWidget) -> UInt64 {
        widget.output().withUnsafeBytes {
            let header = $0.loadUnaligned(as: omni_wire_header.self)
            return header.deps | (header.flags & OMNI_WIRE_AUDIO == 0 ? 0 : ShellDataKey.spectrum.bit)
        }
    }

    func shapes(_ widget: ShellRenderedWidget) -> [ShellGlassShape] {
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.spectrum.bindings.values.compactMap(\.target).sorted { $0.slot < $1.slot }
        }
    }

    private func capReports(_ widget: ShellRenderedWidget) -> Int {
        (0 ..< omni_instance_message_count(widget.instance, OMNI_MESSAGE_LOG)).count { index in
            var length = 0
            guard let bytes = omni_instance_message(widget.instance, OMNI_MESSAGE_LOG, index, &length)
            else { return false }
            return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
                .contains("Visualiser capped")
        }
    }

    func columns(_ fixture: Fixture) throws -> [Column] {
        try fixture.widget.strings().filter { $0.hasPrefix("c ") }.map { line in
            let values = line.split(separator: " ").dropFirst().compactMap { Double($0) }
            guard values.count == 10 else { throw XCTUnwrapFailure.invalidColumn(line) }
            return Column(
                index: Int(values[0]), band: values[1], base: CGPoint(x: values[2], y: values[3]),
                direction: CGVector(dx: values[4], dy: values[5]), width: values[6], radius: values[7],
                taper: values[8], rotation: values[9]
            )
        }
    }

    private enum XCTUnwrapFailure: Error {
        case invalidColumn(String)
    }

    func testDefaultOffAndUnselectedDisplayNeverDemandAudioOrCreateTimers() throws {
        for settings: [String: ShellComponentValue] in [
            [:], ["visualiser": .bool(false)],
            ["visualiser": .bool(true), "mon": .string(VitreusFixture.secondary)]
        ] {
            let fixture = try fixture(settings: settings)
            XCTAssertEqual(dependencies(fixture.widget) & ShellDataKey.spectrum.bit, 0)
            XCTAssertEqual(dependencies(fixture.widget) & ShellDataKey.tempo.bit, 0)
            XCTAssertEqual(shapes(fixture.widget).count, 0)
            var request = omni_service_request()
            while omni_vm_next_service(fixture.widget.vm, &request) {
                XCTAssertNotEqual(request.kind, OMNI_SERVICE_TIMER)
            }
        }
        for display in [VitreusFixture.primary, VitreusFixture.bar(monitor).monitorId] {
            let fixture = try fixture(settings: ["visualiser": .bool(true), "mon": .string(display)])
            XCTAssertNotEqual(dependencies(fixture.widget) & ShellDataKey.spectrum.bit, 0)
            XCTAssertEqual(shapes(fixture.widget).count, 24)
        }
        let empty = try fixture(budget: 0)
        XCTAssertEqual(dependencies(empty.widget) & ShellDataKey.spectrum.bit, 0)
    }

    func testBudgetCapRoundsFansToQuartetsAndReportsOnlyOnce() throws {
        let fixture = try fixture(settings: ["visualiser": .bool(true), "cols": .number(47)], budget: 13)
        XCTAssertEqual(shapes(fixture.widget).count, 13)
        XCTAssertEqual(capReports(fixture.widget), 1)
        show(fixture)
        XCTAssertEqual(capReports(fixture.widget), 1)
        let fan = try self.fixture(
            settings: ["visualiser": .bool(true), "lay": .string("corners")],
            budget: 14,
            metadata: true
        )
        XCTAssertEqual(try columns(fan).count, 12)
        let empty = try self.fixture(settings: ["visualiser": .bool(true), "lay": .string("corners")], budget: 3)
        XCTAssertEqual(shapes(empty.widget).count, 0)
        XCTAssertEqual(dependencies(empty.widget) & ShellDataKey.spectrum.bit, 0)
    }

    func testVisibleUpdatesUseNativeSpikeSpringsWhileReduceMotionStepsAndParkingNeverFliesIn() throws {
        let fixture = try fixture()
        let widget = fixture.widget
        widget.resources.motion.userAnimationsEnabled = true
        widget.surface.refreshShaders()
        ShellLayerScene.engineQueue.sync {}
        setBands(widget, Array(repeating: 0.9, count: 60))
        let element = try VitreusFixture.element(widget, key: "visualiser-column-11")
        try ShellLayerScene.engineQueue.sync {
            let scene = widget.surface.scene
            let binding = try XCTUnwrap(scene.spectrum.bindings[element.slot])
            XCTAssertEqual(binding.recipe.spring.response, 0.276, accuracy: 0.0001)
            XCTAssertEqual(binding.recipe.spring.bounce, 0.43, accuracy: 0.0001)
            let body = try XCTUnwrap(scene.glassBodies[binding.body ?? -1])
            let native = try XCTUnwrap(body.elements[1][.init(slot: element.slot, part: 0)])
            let animation = try XCTUnwrap(native
                .animation(forKey: ShellGlassBody.Channel.height.key) as? CASpringAnimation)
            XCTAssertGreaterThan(animation.duration, 0)
            XCTAssertEqual(native.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        }
        widget.resources.motion.userAnimationsEnabled = false
        widget.surface.refreshShaders()
        ShellLayerScene.engineQueue.sync {}
        setBands(widget, Array(repeating: 0.3, count: 60))
        ShellLayerScene.engineQueue.sync {
            for body in widget.surface.scene.glassBodies.values {
                for native in body.elements.flatMap(\.values) {
                    XCTAssertNil(native.animation(forKey: ShellGlassBody.Channel.height.key))
                }
            }
        }
        setBands(widget, [])
        widget.resources.motion.userAnimationsEnabled = true
        widget.surface.refreshShaders()
        ShellLayerScene.engineQueue.sync {}
        setBands(widget, Array(repeating: 0.8, count: 60))
        try ShellLayerScene.engineQueue.sync {
            let binding = try XCTUnwrap(widget.surface.scene.spectrum.bindings[element.slot])
            let target = try XCTUnwrap(binding.targets.values.first?.first)
            XCTAssertLessThan(target.position.x, 1512)
            XCTAssertNil(target.animation(forKey: ShellGlassBody.Channel.x.key))
            XCTAssertNil(target.animation(forKey: ShellGlassBody.Channel.height.key))
        }
        XCTAssertNil(widget.surface.animation(for: element))
    }
}
