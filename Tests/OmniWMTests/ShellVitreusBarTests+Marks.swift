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

    private static let oneIconRun = 21.0

    private func markWorkspace(
        _ id: String, name: String? = nil, occupied: Bool = false, focused: Bool = false
    ) -> ShellBarWorkspace {
        let items: [ShellBarItem] = occupied ? [ShellBarItem(
            id: "app-" + id, bundle: "test.app." + id, name: "App " + id, focused: focused,
            count: 1, hidden: 0, windows: [.init(
                id: "window-" + id,
                title: "Window " + id,
                focused: focused,
                hidden: false
            )]
        )] : []
        return ShellBarWorkspace(id: id, name: name ?? id, focused: focused, windows: items)
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

    func testIconsDragAndWorkspaceZonesAcceptDrops() throws {
        let widget = try markWidget(markData())
        let targets = widget.surface.targetFrames().map { (name: widget.text.string($0.target), drop: $0.drop) }
        for id in ["1", "2", "3", "4"] {
            XCTAssertTrue(targets.contains { $0.name == "workspace " + id && $0.drop }, id)
        }
        for id in ["1", "2", "4"] {
            XCTAssertTrue(targets.contains { $0.name == "window app-" + id && !$0.drop }, id)
        }
    }

    func testAWorkspacesDropAreaCoversItsIconsAndIgnoresTheGap() throws {
        var data = markData()
        let rest = try markWidget(data)
        let area = try VitreusFixture.frame(rest, key: "workspace-drop-2")
        let mark = try VitreusFixture.frame(rest, key: "workspace-hit-2")
        let icon = try VitreusFixture.frame(rest, key: "workspace-icon-2-app-2")
        XCTAssertLessThanOrEqual(area.minX, mark.minX)
        XCTAssertGreaterThanOrEqual(area.maxX, icon.maxX)
        data.drag = ShellBarDrag(sources: ["app-1"], gaps: [.init(workspace: "2", before: 2)])
        let dragged = try markWidget(data)
        XCTAssertEqual(try VitreusFixture.frame(dragged, key: "workspace-drop-2"), area)
        XCTAssertLessThan(try VitreusFixture.frame(dragged, key: "workspace-icon-2-app-2").minX, icon.minX)
    }

    func testDragDimsItsSourceLightsItsTargetAndOpensAGapBetweenIcons() throws {
        let unit = 1.35
        var data = markData()
        let extra = ShellBarItem(
            id: "app-4b", bundle: "test.app.4b", name: "App 4b", focused: false,
            count: 1, hidden: 0, windows: [.init(id: "window-4b", title: "Window 4b", focused: false, hidden: false)]
        )
        data.workspaces[3] = ShellBarWorkspace(
            id: "4", name: "4", focused: false, windows: markWorkspace("4", occupied: true).windows + [extra]
        )
        let rest = try markWidget(data)
        let restSquare = try VitreusFixture.frame(rest, key: "workspace-square-3")
        let restFirst = try VitreusFixture.frame(rest, key: "workspace-icon-4-app-4")
        let restSecond = try VitreusFixture.frame(rest, key: "workspace-icon-4-app-4b")
        data.drag = ShellBarDrag(
            sources: ["app-2"],
            workspaces: ["3"],
            icons: ["app-1"],
            gaps: [.init(workspace: "4", before: 2)]
        )
        let widget = try markWidget(data)
        XCTAssertEqual(try markPaint(widget, "workspace-glyph-2-app-2").opacity, 0.35)
        XCTAssertGreaterThan(try VitreusFixture.frame(widget, key: "workspace-square-3").width, restSquare.width)
        XCTAssertEqual(Double(try markPaint(widget, "workspace-icon-1-app-1").strokeWidth), floatStored(1.5 * unit))
        let first = try VitreusFixture.frame(widget, key: "workspace-icon-4-app-4")
        let second = try VitreusFixture.frame(widget, key: "workspace-icon-4-app-4b")
        let shift = 0.2 * restFirst.width
        let bound = CGFloat.floatRounding(operations: 8, at: restSecond.maxX)
        XCTAssertEqual(first.minX, restFirst.minX - shift, accuracy: bound)
        XCTAssertEqual(second.minX, restSecond.minX + shift, accuracy: bound)
    }

    func testWorkspaceMarkSizesGapsAndRestingPillScaleWithTheBar() throws {
        for size in [1.0, 0.7] {
            let widget = try markWidget(markData(), size: size)
            let unit = 1.35 * size
            let shell = try VitreusFixture.frame(widget, key: "shell")
            let origin = shell.minX + 16 * unit
            let pill = try VitreusFixture.frame(widget, key: "workspace-pill-shape")
            Self.assertRect(pill, CGRect(x: origin, y: shell.midY - 7.5 * unit, width: 29 * unit, height: 15 * unit))
            let occupied = try VitreusFixture.frame(widget, key: "workspace-square-2")
            Self.assertRect(occupied, CGRect(
                x: origin + (38 + Self.oneIconRun) * unit, y: shell.midY - 6.25 * unit,
                width: 12.5 * unit, height: 12.5 * unit
            ))
            let empty = try VitreusFixture.frame(widget, key: "workspace-square-3")
            XCTAssertEqual(
                empty.minX - occupied.maxX,
                (9 + Self.oneIconRun) * unit,
                accuracy: .floatRounding(operations: 11, at: empty.maxX)
            )
            XCTAssertEqual(empty.size, occupied.size)
            let next = try VitreusFixture.frame(widget, key: "workspace-square-4")
            XCTAssertEqual(next.minX - empty.maxX, 9 * unit, accuracy: .floatRounding(operations: 11, at: next.maxX))
            let radius = try markPaint(widget, "workspace-square-2").cornerRadius
            XCTAssertEqual(Double(radius), floatStored(3.75 * unit))
            let hit = try VitreusFixture.frame(widget, key: "workspace-hit-2")
            XCTAssertEqual(hit.width, floatStored(21.5 * unit))
            XCTAssertEqual(hit.height, shell.height)
            let activeHit = try VitreusFixture.frame(widget, key: "workspace-hit-1")
            XCTAssertEqual(
                activeHit.maxX + Self.oneIconRun * unit,
                hit.minX,
                accuracy: .floatRounding(operations: 7, at: hit.maxX)
            )
        }
    }

    func testWorkspaceRowGrowsForEveryWorkspaceAndItsIcons() throws {
        var data = markData()
        data.workspaces = (1 ... 9).map { markWorkspace(String($0), occupied: true, focused: $0 == 1) }
        let widget = try markWidget(data)
        let pill = try VitreusFixture.frame(widget, key: "shell")
        let row = 29 + 9 + 8 * (12.5 + 9) + 9 * Self.oneIconRun
        XCTAssertEqual(pill.width, floatStored((450 + row - 128) * 1.35))
        let last = try VitreusFixture.frame(widget, key: "workspace-hit-9")
        XCTAssertLessThan(last.maxX, pill.maxX - 16 * 1.35)
    }

    func testEveryWorkspaceShowsItsNameInATileThatFitsIt() throws {
        var data = markData()
        data.workspaces = [
            markWorkspace("1", name: "Browser", occupied: true, focused: true),
            markWorkspace("2", name: "Mail", occupied: true),
            markWorkspace("3", name: "3")
        ]
        let widget = try markWidget(data)
        let unit = 1.35
        XCTAssertTrue(Set(["Browser", "Mail", "3"]).isSubset(of: widget.strings()))
        for (id, square) in [("1", "workspace-pill-shape"), ("2", "workspace-square-2"), ("3", "workspace-square-3")] {
            let text = try VitreusFixture.frame(widget, key: "workspace-name-text-" + id)
            let tile = try VitreusFixture.frame(widget, key: square)
            XCTAssertEqual(text.midX, floatStored(tile.midX), id)
            XCTAssertEqual(text.midY, tile.midY, id)
            XCTAssertLessThanOrEqual(text.width, tile.width, id)
            let hit = try VitreusFixture.frame(widget, key: "workspace-hit-" + id)
            XCTAssertEqual(hit.width, floatStored(tile.width + 9 * unit), id)
        }
        let pill = try VitreusFixture.frame(widget, key: "workspace-pill-shape")
        let browser = try VitreusFixture.frame(widget, key: "workspace-name-text-1")
        XCTAssertGreaterThan(pill.width, 29 * unit)
        XCTAssertEqual(pill.width, floatStored(browser.width + 6 * unit))
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "workspace-square-3").width, 12.5 * unit)
    }

    func testTurningWorkspaceLabelsOffLeavesBlankMarksAtTheirOwnSizes() throws {
        var data = markData()
        data.workspaces = [
            markWorkspace("1", name: "Browser", occupied: true, focused: true),
            markWorkspace("2", name: "Mail", occupied: true),
            markWorkspace("3", name: "Empty")
        ]
        data.style.labels = false
        let widget = try markWidget(data)
        let unit = 1.35
        XCTAssertFalse(widget.strings().contains("Browser"))
        XCTAssertFalse(Self.has(widget, "workspace-name-1"))
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "workspace-pill-shape").width, floatStored(29 * unit))
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "workspace-square-2").width, 12.5 * unit)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "workspace-square-3").width, floatStored(8 * unit))
    }

    func testWorkspaceFlatBodiesDeclareReferenceOpacityRimsGradientAndGlow() throws {
        let widget = try markWidget(markData())
        let square = try markRecipe(widget, "workspace-mark-2")
        let pill = try markRecipe(widget, "workspace-pill")
        XCTAssertTrue(square.flat)
        XCTAssertTrue(pill.flat)
        XCTAssertEqual(square.rim, 0.4)
        XCTAssertEqual(pill.rim, 0.55)
        XCTAssertEqual(pill.gradientAngle, 90)
        let squarePaint = try markPaint(widget, "workspace-mark-2")
        XCTAssertEqual(squarePaint.opacity, 0.4675)
        XCTAssertEqual(squarePaint.fill.role & 0xFF, UInt16(ShellRole.foreground.rawValue + 1))
        let pillPaint = try markPaint(widget, "workspace-pill")
        XCTAssertEqual(pillPaint.opacity, 0.55)
        XCTAssertTrue(pillPaint.gradientSpecified)
        XCTAssertEqual(pillPaint.gradientFrom.role & 0xFF, UInt16(ShellRole.secondaryContainerForeground.rawValue + 1))
        XCTAssertEqual(pillPaint.gradientTo.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
        XCTAssertEqual(pillPaint.shadowRadius, 7 * 1.35)
        XCTAssertEqual(pillPaint.shadow.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
        XCTAssertEqual(Double(pillPaint.shadow.role >> 8) / 255, (0.3 * 255).rounded() / 255)
        XCTAssertEqual(pill.shadowOffset, .zero)
    }

    func testWorkspacePillDeclaresIndependentLeadAndTrailAndKeepsMovingNatively() throws {
        let widget = try markWidget(markData(), animations: true)
        let clock = MarkClock()
        widget.surface.clock = { clock.time }
        let shape = try VitreusFixture.element(widget, key: "workspace-pill-shape")
        let paint = widget.surface.layout.core.paint(of: shape)
        let morph = try XCTUnwrap(ShellMorphRecipe(widget.text.string(paint.morph)))
        let edges = try XCTUnwrap(morph.edges)
        XCTAssertEqual(edges.lead.response, 0.142)
        XCTAssertEqual(edges.lead.bounce, 0)
        XCTAssertEqual(edges.trail.response, 0.378)
        XCTAssertEqual(edges.trail.bounce, 0)
        XCTAssertEqual(edges.thin, 0.18)
        XCTAssertEqual(edges.unit, 29.75 * 1.35)
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

    func testBusyAndEmptyWorkspacesAreClickableWithNoOverviewOrPlus() throws {
        for (key, command) in [("workspace-hit-2", "switch-workspace 2"), ("workspace-hit-3", "switch-workspace 3")] {
            let widget = try markWidget(markData())
            try VitreusFixture.click(widget, key: key)
            XCTAssertEqual(widget.clicks.last?.action, command)
            XCTAssertFalse(widget.tree().contains { widget.text.string($0.content.text) == "toggle-overview" })
            for removed in ["workspace-overview", "workspace-overview-icon", "workspace-new", "workspace-plus"] {
                XCTAssertFalse(Self.has(widget, removed), removed)
            }
        }
        let empty = try markWidget(markData(emptyActive: true))
        XCTAssertTrue(Self.has(empty, "workspace-hit-1"))
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
        XCTAssertEqual(pending.seconds, 0.2)
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
            let pending = try XCTUnwrap(VitreusFixture.drain(widget).first { $0.kind == OMNI_SERVICE_TIMER })
            XCTAssertEqual(pending.seconds, 0.2)
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
        XCTAssertEqual(frame.midX, target.midX, accuracy: .floatRounding(operations: 8, at: target.maxX))
        XCTAssertEqual(frame.width, floatStored(29 * 1.35))
        XCTAssertEqual(frame.height, 15 * 1.35)
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
            XCTAssertEqual(square.width, floatStored(12.5 * 1.35 * size * 1.35))
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
            guard body.nativeAvailable
            else { throw MissingTestPrerequisite(body.failure ?? "Native glass is unavailable") }
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
            ("workspace-pill", "workspace-pill-shape")
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
