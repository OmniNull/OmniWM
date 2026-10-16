// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import IOSurface
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class ShellBarShaderTests: XCTestCase {
    private func program() throws -> ShellShaderProgram {
        let source = """
        float4 shade(float2 uv, constant OmniShader& shader) {
            return float4(uv.x, shader.scale / 2.0, 0, 1);
        }
        """
        let pipeline = try ShellShaderLibrary.pipeline(Data(source.utf8), name: "bar-test.metal")
        let program = ShellShaderProgram(name: "bar-test.metal")
        program.finish(pipeline, failure: nil)
        return program
    }

    private var input: ShellShaderInput {
        ShellShaderInput(values: .zero, rate: 0, colors: .init(repeating: .zero))
    }

    func testBarShaderFillsWideAndVerticalBarsWithinTheExistingPixelBudget() async throws {
        let program = try program()
        for size in [CGSize(width: 6144, height: 40), CGSize(width: 40, height: 6144)] {
            let view = ShellBarShaderView()
            view.setFrameSize(size)
            view.update(program: program, input: input, paused: false)
            let scene = try XCTUnwrap(view.scene)
            scene.submit([.visibility(true)], animated: false)
            await until {
                ShellLayerScene.engineQueue.sync { scene.layers[0]?.contents is IOSurface }
            }
            let rendered = try XCTUnwrap(ShellLayerScene.engineQueue.sync { scene.layers[0]?.contents as? IOSurface })
            XCTAssertLessThanOrEqual(rendered.width, ShellShaderDrawer.maximumPixels)
            XCTAssertLessThanOrEqual(rendered.height, ShellShaderDrawer.maximumPixels)
            XCTAssertEqual(max(rendered.width, rendered.height), ShellShaderDrawer.maximumPixels)
            XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers[0]?.bounds.size }, size)
            rendered.lock(options: .readOnly, seed: nil)
            let last = rendered.baseAddress.load(fromByteOffset: (rendered.width - 1) * 4, as: UInt32.self)
            rendered.unlock(options: .readOnly, seed: nil)
            XCTAssertGreaterThan((last >> 16) & 255, 245)
            XCTAssertEqual(last >> 24, 255)
            view.stop()
            XCTAssertTrue(ShellLayerScene.engineQueue.sync { scene.layers.isEmpty })
        }
    }

    func testGeometryKeepsTheSceneUntilItsRenderScaleChangesAndNeverTakesClicks() throws {
        let view = ShellBarShaderView()
        view.setFrameSize(CGSize(width: 1000, height: 40))
        view.update(program: try program(), input: input, paused: false)
        let original = try XCTUnwrap(view.scene)
        XCTAssertEqual(view.renderScale, 2)
        XCTAssertFalse(view.visible)
        XCTAssertNil(view.hitTest(CGPoint(x: 5, y: 5)))
        view.setFrameSize(CGSize(width: 1600, height: 50))
        XCTAssertTrue(view.scene === original)
        XCTAssertEqual(
            ShellLayerScene.engineQueue.sync { original.layers[0]?.bounds.size },
            CGSize(width: 1600, height: 50)
        )
        view.setFrameSize(CGSize(width: 6000, height: 40))
        XCTAssertFalse(view.scene === original)
        XCTAssertTrue(ShellLayerScene.engineQueue.sync { original.layers.isEmpty })
        XCTAssertLessThan(view.renderScale, 1)
        view.stop()
    }

    func testShaderBackgroundUsesBarBoundsWithoutChangingItsMeasuredSize() {
        var snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 1, barHeight: 40,
            barShader: ShellBarShader(source: "matrix-rain.metal")
        )
        let model = WorkspaceBarModel(snapshot: snapshot)
        model.zones = WorkspaceBarZones(notch: nil, mode: .splitAroundNotch)
        let background = ShellBarShaderView()
        let view = NSHostingView(rootView: WorkspaceBarView(
            model: model, motionPolicy: MotionPolicy(animationsEnabled: false),
            shaderBackground: { background }
        ).frame(width: 1000, height: 40))
        view.setFrameSize(CGSize(width: 1000, height: 40))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize, CGSize(width: 1000, height: 40))
        XCTAssertEqual(background.frame.size, CGSize(width: 1000, height: 40))
        XCTAssertEqual(snapshot.replacingShellWidgets([]).barShader, snapshot.barShader)
        snapshot.barShader = nil
        XCTAssertNotEqual(snapshot, model.snapshot)
    }

    func testHostReusesBackgroundsAndRetiresThemPerDisplayOrProfile() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = ShellWidgetHost(
            configDirectory: directory, resources: ShellResources(motion: MotionPolicy()),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] },
            onLayoutChange: {}, onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in },
            onDrag: { _ in }, onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        host.started = true
        host.config.barShader = ShellBarShader(source: "missing.metal")
        let key = ShellBarKey(monitor: .init(displayId: 7))
        let other = ShellBarKey(monitor: .init(displayId: 8))
        let first = host.barShaderView(key: key)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === host.barShaderView(key: key))
        XCTAssertNotNil(host.barShaderView(key: other))
        XCTAssertNil(host.barShaderView(key: ShellBarKey(monitor: key.monitor, placement: .island)))
        host.removeSurfaces(for: key.monitor)
        XCTAssertNil(host.barShaderViews[key])
        XCTAssertNotNil(host.barShaderViews[other])
        host.config.barShader = nil
        host.refreshBarShaders()
        XCTAssertTrue(host.barShaderViews.isEmpty)
        XCTAssertNil(host.barShaderView(key: other))
        host.stop()
    }

    func testBackgroundStaysAttachedAcrossFullWidthChangesForBothAnimatedProfiles() async throws {
        for source in ["sakura-petals.metal", "matrix-rain.metal"] {
            let model = WorkspaceBarModel(snapshot: WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: [], scratchpads: []),
                backgroundOpacity: 1, barHeight: 40,
                barFill: ShellThemeColor("background", theme: .native),
                barBorder: ShellThemeColor("border", theme: .native),
                barShader: ShellBarShader(source: source)
            ))
            let background = ShellBarShaderView()
            background.update(program: try program(), input: input, paused: false)
            let view = NSHostingView(rootView: WorkspaceBarView(
                model: model, motionPolicy: MotionPolicy(animationsEnabled: false),
                shaderBackground: { background }
            ))
            view.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 40),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(background.window === window, source)
            XCTAssertTrue(background.isDescendant(of: view), source)

            model.zones = WorkspaceBarZones(notch: nil, mode: .splitAroundNotch)
            view.layoutSubtreeIfNeeded()
            await until { background.frame.size == CGSize(width: 1000, height: 40) }
            XCTAssertTrue(background.window === window, source)
            XCTAssertTrue(background.isDescendant(of: view), source)

            model.zones = nil
            view.layoutSubtreeIfNeeded()
            await until { background.frame.width < 1000 }
            XCTAssertTrue(background.window === window, source)
            XCTAssertTrue(background.isDescendant(of: view), source)
            background.stop()
        }
    }

    func testBackgroundReplacementUpdatesTheHostedView() async {
        let model = WorkspaceBarModel(snapshot: WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 1, barHeight: 40,
            barShader: ShellBarShader(source: "matrix-rain.metal")
        ))
        model.zones = WorkspaceBarZones(notch: nil, mode: .splitAroundNotch)
        let motion = MotionPolicy(animationsEnabled: false)
        let first = ShellBarShaderView()
        let second = ShellBarShaderView()
        let view = NSHostingView(rootView: WorkspaceBarView(
            model: model, motionPolicy: motion, shaderBackground: { first }
        ).frame(width: 1000, height: 40))
        view.setFrameSize(CGSize(width: 1000, height: 40))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(first.isDescendant(of: view))
        view.rootView = WorkspaceBarView(
            model: model, slice: .active, motionPolicy: motion, shaderBackground: { second }
        ).frame(width: 1000, height: 40)
        view.layoutSubtreeIfNeeded()
        await until { second.isDescendant(of: view) && !first.isDescendant(of: view) }
        XCTAssertEqual(second.frame.size, CGSize(width: 1000, height: 40))
    }
}
