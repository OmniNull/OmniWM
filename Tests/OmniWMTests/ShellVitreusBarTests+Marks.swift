// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

extension ShellVitreusBarTests {
    private final class MarkClock {
        var time = CACurrentMediaTime()
    }

    private func markWorkspace(_ id: String, occupied: Bool = false, focused: Bool = false) -> ShellBarWorkspace {
        let items: [ShellBarItem] = occupied ? [ShellBarItem(
            id: "app-" + id, bundle: "test.app." + id, name: "App " + id, focused: focused,
            count: 1, hidden: 0, windows: [.init(
                id: "window-" + id,
                title: "Window " + id,
                focused: focused,
                hidden: false
            )]
        )] : []
        return ShellBarWorkspace(id: id, name: "Room " + id, focused: focused, windows: items)
    }

    private func markData(active: String = "1", emptyActive: Bool = false) -> ShellBarData {
        var data = VitreusFixture.bar()
        data.workspaces = [
            markWorkspace("1", occupied: !emptyActive || active != "1", focused: active == "1"),
            markWorkspace("2", occupied: !emptyActive || active != "2", focused: active == "2"),
            markWorkspace("3"), markWorkspace("4", occupied: true)
        ]
        return data
    }

    private func markWidget(
        _ data: ShellBarData, size: Double = 1, animations: Bool = false
    ) throws -> ShellRenderedWidget {
        let folder = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(folder), scale: 1,
            resources: VitreusFixture.resources(folder, animations: animations)
        )
        VitreusFixture.settings(widget, ["pieces": .strings(["workspaces"]), "size": .number(size)])
        VitreusFixture.show(widget, bar: data)
        return widget
    }

    private func markPaint(_ widget: ShellRenderedWidget, _ key: String) throws -> Paint {
        try widget.surface.layout.core.paint(of: VitreusFixture.element(widget, key: key))
    }

    private func markRecipe(_ widget: ShellRenderedWidget, _ key: String) throws -> ShellGlassRecipe {
        let handle = try VitreusFixture.element(widget, key: key)
        return try XCTUnwrap(ShellGlassRecipe(widget.text.string(widget.surface.layout.core.content(of: handle).text)))
    }

    private func markHover(_ widget: ShellRenderedWidget, _ key: String, _ phase: ShellEvent.Phase) throws {
        let handle = try VitreusFixture.element(widget, key: key)
        let action = widget.surface.layout.core.content(of: handle).hoverAction
        XCTAssertNotEqual(action, 0)
        var event = ShellEvent()
        event.phase = phase
        widget.invoke(action, event: event)
    }

    func testWorkspaceMarkSizesGapsAndRestingPillScaleWithTheBar() throws {
        for size in [1.0, 0.7] {
            let widget = try markWidget(markData(), size: size)
            let unit = 1.35 * size
            let shell = try VitreusFixture.frame(widget, key: "shell")
            let origin = shell.minX + (16 + 25.5) * unit
            let pill = try VitreusFixture.frame(widget, key: "workspace-pill-shape")
            Self.assertRect(pill, CGRect(x: origin, y: shell.midY - 7.5 * unit, width: 29 * unit, height: 15 * unit))
            let occupied = try VitreusFixture.frame(widget, key: "workspace-square-2")
            Self.assertRect(occupied, CGRect(
                x: origin + 38 * unit, y: shell.midY - 6.25 * unit, width: 12.5 * unit, height: 12.5 * unit
            ))
            let next = try VitreusFixture.frame(widget, key: "workspace-square-4")
            XCTAssertEqual(next.minX - occupied.maxX, 9 * unit, accuracy: 0.001)
            XCTAssertFalse(Self.has(widget, "workspace-hit-3"))
            let radius = try markPaint(widget, "workspace-square-2").cornerRadius
            XCTAssertEqual(Double(radius), 3.75 * unit, accuracy: 0.001)
            let hit = try VitreusFixture.frame(widget, key: "workspace-hit-2")
            XCTAssertEqual(hit.width, 21.5 * unit, accuracy: 0.001)
            XCTAssertEqual(hit.height, shell.height, accuracy: 0.001)
            let activeHit = try VitreusFixture.frame(widget, key: "workspace-hit-1")
            XCTAssertEqual(activeHit.maxX, hit.minX, accuracy: 0.001)
            let overview = try VitreusFixture.frame(widget, key: "workspace-overview")
            XCTAssertEqual(Float(overview.width), Float(26 * unit))
            XCTAssertEqual(Float(overview.height), Float(26 * unit))
            XCTAssertEqual(
                widget.surface.command(at: CGPoint(x: overview.maxX - unit / 2, y: overview.midY)),
                "toggle-overview"
            )
        }
    }

    func testWorkspaceRowGrowsForOccupiedRoomsAndReservesTheHiddenPlusSlot() throws {
        var data = markData()
        data.workspaces = (1 ... 10).map { markWorkspace(String($0), occupied: true, focused: $0 == 1) }
        let widget = try markWidget(data)
        let pill = try VitreusFixture.frame(widget, key: "shell")
        XCTAssertEqual(pill.width, (450 + 271 - 128) * 1.35, accuracy: 0.001)
        XCTAssertFalse(Self.has(widget, "workspace-new"))
        let last = try VitreusFixture.frame(widget, key: "workspace-hit-10")
        XCTAssertLessThan(last.maxX, pill.maxX - 16 * 1.35)
    }

    func testWorkspaceFlatBodiesDeclareReferenceOpacityRimsGradientAndGlow() throws {
        let widget = try markWidget(markData())
        let square = try markRecipe(widget, "workspace-mark-2")
        let pill = try markRecipe(widget, "workspace-pill")
        let plus = try markRecipe(widget, "workspace-plus")
        XCTAssertTrue(square.flat)
        XCTAssertTrue(pill.flat)
        XCTAssertTrue(plus.flat)
        XCTAssertEqual(square.rim, 0.4, accuracy: 0.0001)
        XCTAssertEqual(pill.rim, 0.55, accuracy: 0.0001)
        XCTAssertEqual(plus.rim, 0.3, accuracy: 0.0001)
        XCTAssertEqual(pill.gradientAngle, 90)
        let squarePaint = try markPaint(widget, "workspace-mark-2")
        XCTAssertEqual(squarePaint.opacity, 0.4675, accuracy: 0.0001)
        XCTAssertEqual(squarePaint.fill.role & 0xFF, UInt16(ShellRole.foreground.rawValue + 1))
        let pillPaint = try markPaint(widget, "workspace-pill")
        XCTAssertEqual(pillPaint.opacity, 0.55, accuracy: 0.0001)
        XCTAssertTrue(pillPaint.gradientSpecified)
        XCTAssertEqual(pillPaint.gradientFrom.role & 0xFF, UInt16(ShellRole.secondaryContainerForeground.rawValue + 1))
        XCTAssertEqual(pillPaint.gradientTo.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
        XCTAssertEqual(pillPaint.shadowRadius, 7 * 1.35, accuracy: 0.001)
        XCTAssertEqual(pillPaint.shadow.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
        XCTAssertEqual(Double(pillPaint.shadow.role >> 8) / 255, 0.3, accuracy: 0.003)
        XCTAssertEqual(pill.shadowOffset, .zero)
        let plusHorizontal = try VitreusFixture.frame(widget, key: "workspace-plus-h")
        let plusVertical = try VitreusFixture.frame(widget, key: "workspace-plus-v")
        XCTAssertEqual(plusHorizontal.width, 14 * 0.62 * 1.35, accuracy: 0.001)
        XCTAssertEqual(plusHorizontal.height, 1.6 * 1.35, accuracy: 0.001)
        XCTAssertEqual(plusHorizontal.midX, plusVertical.midX, accuracy: 0.001)
        XCTAssertEqual(plusHorizontal.midY, plusVertical.midY, accuracy: 0.001)
        XCTAssertEqual(plusHorizontal.width, plusVertical.height, accuracy: 0.001)
    }

    func testWorkspacePillDeclaresIndependentLeadAndTrailAndKeepsMovingNatively() throws {
        let widget = try markWidget(markData(), animations: true)
        let clock = MarkClock()
        widget.surface.clock = { clock.time }
        let shape = try VitreusFixture.element(widget, key: "workspace-pill-shape")
        let paint = widget.surface.layout.core.paint(of: shape)
        let morph = try XCTUnwrap(ShellMorphRecipe(widget.text.string(paint.morph)))
        let edges = try XCTUnwrap(morph.edges)
        XCTAssertEqual(edges.lead.response, 0.142, accuracy: 0.0001)
        XCTAssertEqual(edges.lead.bounce, 0)
        XCTAssertEqual(edges.trail.response, 0.378, accuracy: 0.0001)
        XCTAssertEqual(edges.trail.bounce, 0)
        XCTAssertEqual(edges.thin, 0.18, accuracy: 0.0001)
        XCTAssertEqual(edges.unit, 29.75 * 1.35, accuracy: 0.001)
        clock.time += 0.01
        VitreusFixture.show(widget, bar: markData(active: "2"))
        let scene = widget.surface.scene
        let slot = try VitreusFixture.element(widget, key: "workspace-pill-shape").slot
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(scene.shapeTracks.entries[slot])
            XCTAssertNotNil(entry.edges)
            XCTAssertGreaterThan(entry.duration, 0)
            XCTAssertGreaterThan(entry.shape(at: entry.begin + 0.05).rect.width, entry.terminal.rect.width)
            XCTAssertLessThan(entry.shape(at: entry.begin + 0.05).rect.height, entry.terminal.rect.height)
            let sampled = entry.shape(at: entry.begin + 0.05)
            print("I2@50ms \(sampled.rect); r \(sampled.radius), proportional \(0.3 * sampled.rect.height)")
        }
    }

    func testWorkspaceMarksAndPlusDispatchExistingCommandsAndEmptyActiveHidesPlus() throws {
        for (key, command) in [
            ("workspace-hit-2", "switch-workspace 2"), ("workspace-new", "switch-workspace 3"),
            ("workspace-overview", "toggle-overview")
        ] {
            let widget = try markWidget(markData())
            try VitreusFixture.click(widget, key: key)
            XCTAssertEqual(widget.clicks.last?.action, command)
        }
        let empty = try markWidget(markData(emptyActive: true))
        XCTAssertTrue(Self.has(empty, "workspace-hit-1"))
        XCTAssertFalse(Self.has(empty, "workspace-new"))
        XCTAssertFalse(Self.has(empty, "workspace-plus"))
    }

    func testWorkspaceMarksUseTheSuppliedDisplayAndNilStyleShowsNoMarks() throws {
        let first = try markWidget(markData())
        var data = VitreusFixture.bar(VitreusFixture.monitor(VitreusFixture.secondary, id: 95101))
        data.workspaces = [markWorkspace("other", focused: true), markWorkspace("empty")]
        let second = try markWidget(data)
        XCTAssertTrue(Self.has(first, "workspace-hit-1"))
        XCTAssertFalse(Self.has(first, "workspace-hit-other"))
        XCTAssertTrue(Self.has(second, "workspace-hit-other"))
        XCTAssertFalse(Self.has(second, "workspace-hit-1"))
        var disabled = markData()
        disabled.barEnabled = false
        let absent = try markWidget(disabled)
        XCTAssertFalse(Self.has(absent, "workspace-overview"))
        XCTAssertFalse(Self.has(absent, "workspace-pill"))
        XCTAssertFalse(Self.has(absent, "workspace-hit-2"))
    }

    func testWorkspacePencilTimerStartsOnHoverTicksOnceAndCancelsOnExit() throws {
        let data = markData()
        let widget = try markWidget(data)
        XCTAssertFalse(VitreusFixture.drain(widget).contains { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(omni_vm_service_stats(widget.vm).pending, 0)
        try markHover(widget, "workspace-hit-2", .began)
        VitreusFixture.show(widget, bar: data)
        let pending = try XCTUnwrap(VitreusFixture.drain(widget).first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(pending.seconds, 0.2, accuracy: 0.0001)
        let before = widget.tree().filter { $0.kind == .path }.map { widget.text.string($0.content.text) }
        VitreusFixture.complete(widget, pending)
        VitreusFixture.show(widget, bar: data)
        let after = widget.tree().filter { $0.kind == .path }.map { widget.text.string($0.content.text) }
        XCTAssertNotEqual(before, after)
        let continued = VitreusFixture.drain(widget).filter { $0.kind == OMNI_SERVICE_TIMER }
        XCTAssertEqual(continued.count, 1)
        XCTAssertEqual(omni_vm_service_stats(widget.vm).reserved, 1)
        let cancellations = omni_vm_service_stats(widget.vm).cancellations
        try markHover(widget, "workspace-hit-2", .ended)
        VitreusFixture.show(widget, bar: data)
        XCTAssertEqual(omni_vm_service_stats(widget.vm).pending, 0)
        XCTAssertGreaterThan(omni_vm_service_stats(widget.vm).cancellations, cancellations)
    }

    func testWorkspacePencilTimerCancelsImmediatelyWhenThePieceOrBarDisappears() throws {
        for removed in ["piece", "bar", "island"] {
            var data = markData()
            let widget = try markWidget(data)
            try markHover(widget, "workspace-hit-2", .began)
            VitreusFixture.show(widget, bar: data)
            XCTAssertEqual(omni_vm_service_stats(widget.vm).pending, 1)
            if removed == "piece" {
                VitreusFixture.settings(widget, ["pieces": .strings(["omniwm"])])
            } else if removed == "bar" {
                data.barEnabled = false
            }
            if removed == "island" {
                let monitor = VitreusFixture.monitor()
                widget.set("island") {
                    ShellIslandData(
                        monitor: monitor,
                        geometry: ShellIslandGeometry(monitor: monitor, size: monitor.frame.size),
                        visible: false,
                        fullscreen: false
                    ).write(to: &$0)
                }
                widget.render(data)
            } else {
                VitreusFixture.show(widget, bar: data)
            }
            XCTAssertEqual(omni_vm_service_stats(widget.vm).reserved, 0)
        }
    }

    func testVisibleScratchpadReplacesNormalMarksAndOwnsItsBoilingTimer() throws {
        for name in ["magic", "music", "private"] {
            var data = markData()
            data.scratchpads = [.init(
                id: 7, name: name, focused: true, revealed: true, visible: true,
                windows: [ShellBarItem(
                    id: "scratch",
                    bundle: "test.scratch",
                    name: "Scratch",
                    focused: true,
                    count: 1,
                    hidden: 0,
                    windows: []
                )]
            )]
            let widget = try markWidget(data)
            XCTAssertTrue(Self.has(widget, "workspace-special"), name)
            XCTAssertFalse(Self.has(widget, "workspace-hit-1"), name)
            XCTAssertFalse(Self.has(widget, "workspace-pill"), name)
            XCTAssertFalse(Self.has(widget, "workspace-new"), name)
            let pending = try XCTUnwrap(VitreusFixture.drain(widget).first { $0.kind == OMNI_SERVICE_TIMER })
            XCTAssertEqual(pending.seconds, 0.2, accuracy: 0.0001)
            let frame = try VitreusFixture.frame(widget, key: "workspace-special")
            XCTAssertEqual(widget.surface.command(at: CGPoint(x: frame.midX, y: frame.midY)), "scratchpad toggle 7")
            data.scratchpads[0] = .init(id: 7, name: name, focused: false, revealed: true, visible: false, windows: [])
            VitreusFixture.show(widget, bar: data)
            XCTAssertTrue(Self.has(widget, "workspace-hit-1"), name)
            XCTAssertFalse(Self.has(widget, "workspace-special"), name)
            XCTAssertEqual(omni_vm_service_stats(widget.vm).pending, 0)
        }
    }

    func testReducedMotionMovesThePillStraightToTheNewWorkspace() throws {
        let widget = try markWidget(markData())
        VitreusFixture.show(widget, bar: markData(active: "2"))
        let scene = widget.surface.scene
        let handle = try VitreusFixture.element(widget, key: "workspace-pill-shape")
        let frame = try VitreusFixture.frame(widget, key: "workspace-pill-shape")
        ShellLayerScene.engineQueue.sync {
            if let entry = scene.shapeTracks.entries[handle.slot] {
                XCTAssertEqual(entry.duration, 0)
                XCTAssertEqual(entry.shape(at: .infinity).rect.size, frame.size)
            }
        }
        let target = try VitreusFixture.frame(widget, key: "workspace-hit-2")
        XCTAssertEqual(frame.midX, target.midX, accuracy: 0.001)
        XCTAssertEqual(frame.width, 29 * 1.35, accuracy: 0.001)
        XCTAssertEqual(frame.height, 15 * 1.35, accuracy: 0.001)
    }
}

extension ShellVitreusBarTests {
    private func markSnapshot(_ widget: ShellRenderedWidget, name: String) throws {
        let pill = try VitreusFixture.frame(widget, key: "shell")
        let crop = CGRect(x: floor(pill.minX) - 8, y: 0, width: ceil(pill.width) + 16, height: 90)
        let scale = 1
        let bytes = try VitreusFixture.pixels(widget, crop: crop, scale: scale)
        let width = Int(crop.width) * scale
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: 90 * scale, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue)), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        try ShellVitreusDeskTests.write(image, name: name)
        XCTAssertGreaterThan(bytes.enumerated().filter { $0.offset % 4 == 3 && $0.element > 128 }.count, 100)
    }

    func testWorkspaceNativeSnapshotsCoverRestHoverAndEachSpecialMark() throws {
        let data = markData()
        for size in [1.0, 0.7] {
            let widget = try markWidget(data, size: size)
            try markSnapshot(widget, name: "vitreus-marks-\(size)")
            try markHover(widget, "workspace-hit-2", .began)
            VitreusFixture.show(widget, bar: data)
            let square = try VitreusFixture.frame(widget, key: "workspace-square-2")
            XCTAssertEqual(square.width, 12.5 * 1.35 * size * 1.35, accuracy: 0.001)
            try markSnapshot(widget, name: "vitreus-marks-hover-\(size)")
            try markHover(widget, "workspace-hit-2", .ended)
            VitreusFixture.show(widget, bar: data)
        }
        for name in ["magic", "music", "private"] {
            var special = data
            special.scratchpads = [.init(id: 7, name: name, focused: true, revealed: true, visible: true, windows: [])]
            try markSnapshot(markWidget(special), name: "vitreus-marks-\(name)")
        }
    }

    private nonisolated static func markDistance(_ point: CGPoint, shape: ShellGlassShape) -> Double {
        let dx = abs(point.x - shape.rect.midX) - shape.rect.width / 2 + shape.radius
        let dy = abs(point.y - shape.rect.midY) - shape.rect.height / 2 + shape.radius
        return hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - shape.radius
    }

    private nonisolated static func markRaster(_ owner: CALayer, scale: Int) throws -> ShellOffscreenRenderer {
        let root = CALayer()
        root.frame = CGRect(
            x: 0,
            y: 0,
            width: ceil((owner.bounds.width + 40) * CGFloat(scale)),
            height: ceil((owner.bounds.height + 40) * CGFloat(scale))
        )
        root.isGeometryFlipped = true
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        root.addSublayer(holder)
        holder.addSublayer(owner)
        owner.position = CGPoint(x: 20, y: 20)
        return try ShellOffscreenRenderer(root: root, width: Int(root.frame.width), height: Int(root.frame.height))
    }

    private nonisolated static func markSamples(
        _ lit: [UInt8], plain: [UInt8], shape: ShellGlassShape, style: (opacity: Float, rim: CGFloat),
        raster: (width: Int, scale: Int)
    ) -> [[String: Double]] {
        let scale = Double(raster.scale)
        let first = Int(ceil((20 + shape.rect.minX) * scale))
        let row = Int((20 + shape.rect.midY) * scale)
        return (0 ..< 6 * raster.scale).map { offset in
            let column = first + offset
            let point = CGPoint(x: (Double(column) + 0.5) / scale - 20, y: (Double(row) + 0.5) / scale - 20)
            let distance = markDistance(point, shape: shape)
            let light = 255 * Double(style.rim) * ShellGlassSceneTests.smoothstep(-2.2, -0.4, distance)
            let pixel = (row * raster.width + column) * 4
            let alpha = Double(plain[pixel + 3])
            var reference = 0.0, clippedReference = 0.0, requiredClip = 0.0, actual = 0.0
            for (channel, weight) in [(0, 0.0722), (1, 0.7152), (2, 0.2126)] {
                let base = Double(plain[pixel + channel])
                let exact = min(255, base + light * alpha / 255)
                let clipped = min(alpha, exact)
                clippedReference += weight * (clipped - base)
                requiredClip += weight * (exact - clipped)
                reference += weight * (exact - base)
                actual += weight * Double(Int(lit[pixel + channel]) - Int(plain[pixel + channel]))
            }
            return [
                "distance": distance, "nativeIncrement": actual,
                "pleamarIncrement": reference, "error": actual - reference,
                "clippedIncrement": clippedReference, "clippedError": actual - clippedReference,
                "requiredClip": requiredClip, "nativeBaseAlpha": alpha
            ]
        }
    }

    private nonisolated static func markProfileSummary(
        _ pixels: [UInt8], samples: [[String: Double]], name: (key: String, scale: Int),
        style: (opacity: Float, rim: CGFloat)
    ) -> [String: Any] {
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertLessThanOrEqual(Int(pixels[pixel ..< pixel + 3].max() ?? 0), Int(pixels[pixel + 3]) + 1)
        }
        return [
            "key": name.key, "scale": name.scale,
            "opacity": style.opacity, "rim": style.rim,
            "samples": samples,
            "maximumError": samples.map { abs($0["error"] ?? 0) }.max() ?? 0,
            "maximumClippedError": samples.map { abs($0["clippedError"] ?? 0) }.max() ?? 0,
            "maximumRequiredClip": samples.map { $0["requiredClip"] ?? 0 }.max() ?? 0
        ]
    }

    private func markRimProfile(
        _ widget: ShellRenderedWidget,
        key: String,
        shape: String,
        scale: Int
    ) throws -> [String: Any] {
        let slot = try VitreusFixture.element(widget, key: key).slot
        let sampleSlot = try VitreusFixture.element(widget, key: shape).slot
        let recipe = try markRecipe(widget, key)
        let scene = widget.surface.scene
        return try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[slot])
            guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
            let owner = try XCTUnwrap(scene.layers[slot])
            let geometry = try XCTUnwrap(scene.glassShapes[sampleSlot])
            let band = try XCTUnwrap(body.canvasLayers.first { $0.compositingFilter != nil })
            let parent = owner.superlayer
            let index = parent?.sublayers?.firstIndex(of: owner) ?? 0
            let position = owner.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                band.isHidden = false
                body.sdfLayers[0].isHidden = false
                owner.position = position
                owner.removeFromSuperlayer()
                parent?.insertSublayer(owner, at: UInt32(index))
                CATransaction.commit()
            }
            let width = Int(ceil((owner.bounds.width + 40) * CGFloat(scale)))
            let raster = try Self.markRaster(owner, scale: scale)
            body.sdfLayers[0].isHidden = true
            CATransaction.commit()
            let lit = try raster.render()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.isHidden = true
            CATransaction.commit()
            let plain = try raster.render()
            let samples = Self.markSamples(
                lit,
                plain: plain,
                shape: geometry,
                style: (owner.opacity, recipe.rim),
                raster: (width, scale)
            )
            return Self.markProfileSummary(
                lit,
                samples: samples,
                name: (key, scale),
                style: (owner.opacity, recipe.rim)
            )
        }
    }

    func testWorkspaceTranslucentRimsRecordTheirNativeBandError() throws {
        let widget = try markWidget(markData())
        var profiles: [[String: Any]] = []
        let scale = 2
        for (key, shape) in [
            ("workspace-mark-2", "workspace-square-2"),
            ("workspace-pill", "workspace-pill-shape"),
            ("workspace-plus", "workspace-plus-h")
        ] {
            profiles.append(try markRimProfile(widget, key: key, shape: shape, scale: scale))
        }
        let json = try JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys])
        print("Vitreus translucent rim profiles: " + String(decoding: json, as: UTF8.self))
        if let output = ProcessInfo.processInfo.environment["OMNI_PROBE_OUT"] {
            try json.write(to: URL(fileURLWithPath: output))
        }
    }
}
