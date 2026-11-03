// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Darwin
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellSpectrumShapeTests: XCTestCase {
    private let size = CGSize(width: 1512, height: 982)
    private let spike = ShellAnimation(motion: .spring(response: 0.276, bounce: 0.43), speed: 1)

    private func shape(_ index: Int, level: Double) -> ShellGlassShape {
        let width = (size.width - 21.6) / 47 * 1.9
        let taper = min(1, min(Double(index) + 0.5, 46.5 - Double(index)) / 2.35)
        let height = pow(level, 1.4) * taper * 202.5
        let x = 10.8 + (Double(index) + 0.5) / 47 * (size.width - 21.6)
        return ShellGlassShape(
            slot: Int32(index),
            kind: 0,
            rect: CGRect(
                x: x - width / 2,
                y: size.height - height,
                width: width,
                height: height + 4.05
            ),
            radius: width * 0.45,
            thickness: 0
        )
    }

    private func centered(_ shape: ShellGlassShape, body: ShellGlassBody, motion: ShellGlassBody.Motion?) {
        let transform = CATransform3DMakeRotation(shape.rotation, 0, 0, 1)
        var geometry = ShellGlassBody.Geometry(rect: shape.rect, radius: shape.radius, transform: transform)
        geometry.position = CGPoint(x: shape.rect.midX, y: shape.rect.midY)
        for (track, layers) in body.trackLayers(shape.slot) {
            for layer in layers {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                geometry.apply(to: layer, motion: motion, track: track)
            }
        }
    }

    private func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func testCenteredNativeColumnMatchesTheOrdinaryRotatedGeometry() throws {
        let helper = ShellGlassSceneTests()
        let paint = helper.paint(fill: CGColor(gray: 0.35, alpha: 1))
        let recipe = try XCTUnwrap(ShellGlassRecipe("glass:8:-1:0:0:0|optics:0:1:0"))
        let shape = ShellGlassShape(
            slot: 1,
            kind: 0,
            rect: CGRect(x: 80, y: 55, width: 24, height: 76),
            radius: 10,
            thickness: 0,
            rotation: .pi / 3
        )
        let body = ShellGlassBody()
        body.apply(
            size: CGSize(width: 200, height: 200),
            shapes: [shape],
            recipe: recipe,
            paint: paint,
            animation: nil
        )
        XCTAssertTrue(body.nativeAvailable, body.failure ?? "Native glass unavailable")
        let root = CALayer()
        root.isGeometryFlipped = true
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        root.addSublayer(body.layer)
        let renderer = try ShellOffscreenRenderer(root: root, width: 200, height: 200)
        let before = try renderer.render()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        centered(shape, body: body, motion: nil)
        CATransaction.commit()
        let after = try renderer.render()
        XCTAssertLessThanOrEqual(zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0, 2)
    }

    private struct RouteFixture {
        let widget: ShellRenderedWidget
        let bar: ShellBarData
        let renderer: ShellOffscreenRenderer
    }

    private func routeFixture(luau: Bool, layout: String = "island") throws -> RouteFixture {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let source = try VitreusFixture.source(shell)
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let baseline = try String(
            contentsOf: resources.appendingPathComponent("Fixtures/Spectrum/visualiser-luau.luau"),
            encoding: .utf8
        )
        let modules = source.modules.map { module in
            luau && module.path.hasSuffix("lib/vitreus/visualiser.luau")
                ? ShellWidgetSource.Module(path: module.path, source: baseline) : module
        }
        let widget = try ShellRenderedWidget(
            name: "visualiser-route",
            source: source.main,
            modules: modules,
            chunk: source.chunk,
            resources: VitreusFixture.resources(shell, animations: true),
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders),
            memoryLimit: ShellWidgetPackage.memoryLimit,
            moduleLimit: source.moduleLimit
        )
        widget.configure(ShellComponentCatalog.configurationBytes(
            instances: source.components, descriptors: source.componentDescriptors
        ))
        routeSettings(widget, layout: layout)
        let monitor = VitreusFixture.monitor(width: size.width, height: size.height)
        let bar = VitreusFixture.bar(monitor)
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.spectrum.automatic = false
            widget.surface.scene.spectrum.bands = ShellSpectrumBands()
            widget.surface.scene.spectrum.bands.store(.init(repeating: 0.65))
        }
        widget
            .set("spectrum") {
                ShellSpectrum(access: .granted, bars: .init(repeating: 0.65, count: 60)).write(into: &$0)
            }
        widget.set("island") { VitreusFixture.island(monitor).write(to: &$0) }
        widget.render(bar)
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(origin: .zero, size: size)
            let renderer = try ShellOffscreenRenderer(root: root, width: Int(size.width), height: Int(size.height))
            _ = try renderer.render()
            return renderer
        }
        return RouteFixture(widget: widget, bar: bar, renderer: renderer)
    }

    private func routeSettings(_ widget: ShellRenderedWidget, layout: String) {
        VitreusFixture.settings(widget, [
            "visualiser": .bool(true),
            "cols": .number(47),
            "lay": .string("bottom"),
            "layout": .string(layout),
            "pieces": .strings([
                "workspaces",
                "omniwm",
                "controls"
            ])
        ])
    }

    func testSilentAndPlayingColumnsKeepTheFrameCentreTransparent() throws {
        let fixture = try routeFixture(luau: false, layout: "left")
        let scene = fixture.widget.surface.scene
        for level: Float in [0, 0.8] {
            try ShellLayerScene.engineQueue.sync {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scene.setSpectrumMotion(.init(animationsEnabled: false, animationSpeed: 1))
                scene.spectrum.bands.store(.init(repeating: level))
                scene.stepSpectrum(at: CACurrentMediaTime())
                CATransaction.commit()
                let bytes = try fixture.renderer.render()
                XCTAssertEqual(bytes[(491 * 1512 + 756) * 4 + 3], 0)
                XCTAssertGreaterThan(bytes[(491 * 1512 + 5) * 4 + 3], 20)
                XCTAssertEqual(scene.spectrum.bindings.count, 47)
                XCTAssertTrue(scene.glassBodies.values.allSatisfy(\.nativeAvailable))
            }
        }
    }

    private func measureRoute(_ fixture: RouteFixture, luau: Bool) -> Double {
        let start = cpu()
        for frame in 0 ..< 60 {
            let level = Float(0.25 + Double((frame * 17) % 50) / 100)
            if luau {
                fixture.widget.set("spectrum") {
                    ShellSpectrum(access: .granted, bars: .init(repeating: level, count: 60)).write(into: &$0)
                }
                fixture.widget.render(fixture.bar)
            } else {
                ShellLayerScene.engineQueue.sync {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    fixture.widget.surface.scene.spectrum.bands.store(.init(repeating: level))
                    XCTAssertEqual(
                        fixture.widget.surface.scene.stepSpectrum(at: CACurrentMediaTime()),
                        fixture.widget.surface.scene.spectrum.bindings.count
                    )
                    CATransaction.commit()
                }
            }
        }
        return cpu() - start
    }

    func testOffscreenRouteCostsCompareTheFrozenLuaCandidateWithTheDeliveredDriver() throws {
        let luaFixture = try routeFixture(luau: true)
        let nativeFixture = try routeFixture(luau: false)
        let lua = luaFixture.widget
        let native = nativeFixture.widget
        let slots = try (0 ..< 47).map { try VitreusFixture.element(native, key: "visualiser-column-\($0)").slot }
        let swell = try VitreusFixture.element(native, key: "shell").slot
        ShellLayerScene.engineQueue.sync {
            XCTAssertEqual(Set(native.surface.scene.spectrum.bindings.keys), Set(slots + [swell]))
        }
        var records: [[String: Any]] = []
        let probeOutput = ProcessInfo.processInfo.environment["OMNI_D7_ROUTE_PROBE_OUT"]
        for run in 0 ..< (probeOutput == nil ? 1 : 3) {
            for arm in run.isMultiple(of: 2) ? ["luau", "native"] : ["native", "luau"] {
                let cost = measureRoute(arm == "luau" ? luaFixture : nativeFixture, luau: arm == "luau")
                records.append([
                    "run": run,
                    "arm": arm,
                    "updates": 60,
                    "columns": 47,
                    "processCPUSeconds": cost,
                    "engineCommits": 60,
                    "luaPublications": arm == "luau" ? 60 : 0
                ])
            }
        }
        try ShellLayerScene.engineQueue.sync {
            for (index, slot) in slots.enumerated() {
                let target = try XCTUnwrap(native.surface.scene.spectrum.bindings[slot]?.target)
                let luaSlot = try VitreusFixture.element(lua, key: "visualiser-column-\(index)").slot
                let expected = try XCTUnwrap(lua.surface.scene.glassShapes[luaSlot])
                ShellVitreusBarTests.assertRect(target.rect, expected.rect, "column \(index)")
            }
        }
        if let output = probeOutput {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
        print("D7 delivered route cost", records)
        withExtendedLifetime((luaFixture.renderer, nativeFixture.renderer)) {}
    }
}
