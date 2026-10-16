// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellLakeProfileTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let vm: OpaquePointer
        let instance: OpaquePointer
        let text = ShellTextStore()
        let layout = ShellWidgetLayout()
        var error = [CChar](repeating: 0, count: 512)
        var nodes: [omni_wire_node] = []

        init(source: ShellWidgetSource) throws {
            let created = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            var diagnostics = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(omni_vm_set_module_limit(created, source.moduleLimit), OMNI_OK)
            for module in source.modules {
                XCTAssertEqual(omni_vm_add_module(
                    created,
                    module.path,
                    module.path.utf8.count,
                    module.source,
                    module.source.utf8.count
                ), OMNI_OK)
            }
            XCTAssertEqual(omni_vm_load(
                created,
                source.chunk,
                source.main,
                source.main.utf8.count,
                100_000_000,
                &diagnostics,
                diagnostics.count
            ), OMNI_OK, String(
                decoding: diagnostics.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            ))
            let components = ShellComponentCatalog.configurationBytes(
                instances: source.components,
                descriptors: source.componentDescriptors
            )
            let status = components.withUnsafeBufferPointer {
                omni_vm_configure_components(
                    created,
                    $0.baseAddress,
                    $0.count,
                    100_000_000,
                    &diagnostics,
                    diagnostics.count
                )
            }
            XCTAssertEqual(
                status,
                OMNI_OK,
                String(decoding: diagnostics.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            )
            vm = created
            instance = try XCTUnwrap(omni_instance_create(created))
            error = diagnostics
        }

        isolated deinit {
            omni_instance_destroy(instance)
            _ = omni_vm_destroy(vm)
        }

        func set(_ key: String, _ write: (inout ShellValueWriter) -> Void) {
            var writer = ShellValueWriter()
            write(&writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_set_value(instance, key, $0.baseAddress, $0.count)
            }, OMNI_OK)
        }

        func render() throws {
            var stats = omni_render_stats()
            XCTAssertEqual(omni_instance_render(
                instance,
                OMNI_VIEW_BAR,
                8_000_000,
                &stats,
                &error,
                error.count
            ), OMNI_OK, String(
                decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            ))
            var size = 0
            let output = try XCTUnwrap(omni_instance_output(instance, OMNI_VIEW_BAR, &size))
            let bytes = Array(UnsafeBufferPointer(start: output, count: size))
            text.ingest(wire: bytes)
            nodes = bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride
                            + $0 * MemoryLayout<omni_wire_node>.stride,
                        as: omni_wire_node.self
                    )
                }
            }
            XCTAssertTrue(layout.apply(bytes, text: text))
        }

        func invoke(_ action: UInt32, event supplied: [UInt8]? = nil) {
            let event = supplied ?? ShellEvent().bytes
            XCTAssertEqual(event.withUnsafeBufferPointer {
                omni_instance_invoke(
                    instance,
                    OMNI_VIEW_BAR,
                    action,
                    0,
                    $0.baseAddress,
                    $0.count,
                    25_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }

        var captions: [String] {
            nodes.filter { $0.text != 0 }.map { text.string($0.text) }
        }
    }

    func testUserCopyRendersCompactExpandedAndPromotionWithoutRecreatingWrappers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(in: root)
        for notch in [false, true] {
            let fixture = try Fixture(source: source)
            configure(fixture, notch: notch)
            try fixture.render()
            let primary = try XCTUnwrap(fixture.nodes.first { $0.width > 200 && $0.width < 500 && $0.action != 0 })
            let secondary = try XCTUnwrap(fixture.nodes.first { $0.width == 80 && $0.action != 0 })
            let handles = (0 ..< fixture.layout.patches.count).compactMap { index -> ElementHandle? in
                guard case let .insert(handle, parent, _, _) = fixture.layout.patches.op(at: index),
                      parent == fixture.layout.core.rootHandle,
                      fixture.layout.core.content(of: handle).action != 0 else { return nil }
                return handle
            }
            XCTAssertEqual(handles.count, 2)
            fixture.invoke(secondary.action)
            try fixture.render()
            XCTAssertEqual(Set(fixture.nodes.filter { $0.action != 0 && ($0.width == 80 || $0.width == primary.width) }
                    .map(\.key)), Set([primary.key, secondary.key]))
            XCTAssertTrue(handles.allSatisfy { fixture.layout.core.contains($0) })
            XCTAssertFalse((0 ..< fixture.layout.patches.count).contains { index in
                if case let .remove(handle) = fixture.layout.patches.op(at: index) { return handles.contains(handle) }
                return false
            })
            let promoted = try XCTUnwrap(fixture.nodes.first { $0.key == secondary.key })
            XCTAssertEqual(promoted.width, primary.width)
            fixture.invoke(promoted.action)
            try fixture.render()
            XCTAssertTrue(fixture.nodes.contains { $0.width == 520 })
            XCTAssertTrue(fixture.captions.contains("Agenda"))
            XCTAssertTrue(fixture.captions.contains("Design review"))
        }
    }

    func testExpandedMediaRetainedWorkAndMainActorApplyMeasurement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture(source: source(in: root))
        configure(fixture, notch: true)
        try fixture.render()
        let primary = try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 })
        fixture.invoke(primary.action)
        try fixture.render()
        XCTAssertTrue(fixture.nodes.contains { $0.width == 520 })
        let surface = ShellWidgetSurface(
            scale: 2, resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)), directories: []
        )
        func output() throws -> [UInt8] {
            var length = 0
            let bytes = try XCTUnwrap(omni_instance_output(fixture.instance, OMNI_VIEW_BAR, &length))
            return Array(UnsafeBufferPointer(start: bytes, count: length))
        }
        XCTAssertTrue(surface.apply(try output(), text: fixture.text))
        var durations: [Double] = []
        for sample in 0 ..< 256 {
            fixture.set("media") { writer in
                var media = ShellMedia()
                media.title = "Test track"
                media.artist = "Artist \(sample)"
                media.playing = true
                media.write(into: &writer)
            }
            XCTAssertEqual(
                omni_instance_begin_update(fixture.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit, true), OMNI_OK
            )
            var counts: [UInt32: Int] = [:]
            var done = false
            while !done {
                var step = omni_render_step_stats()
                XCTAssertEqual(omni_instance_step_update(
                    fixture.instance, OMNI_VIEW_BAR, 8_000_000, &step, &fixture.error, fixture.error.count
                ), OMNI_OK)
                XCTAssertEqual(step.unit_status, OMNI_OK)
                counts[step.kind.rawValue, default: 0] += 1
                done = step.done
            }
            XCTAssertEqual(counts[OMNI_RENDER_ROOT.rawValue, default: 0], 0)
            XCTAssertEqual(counts[OMNI_RENDER_COMPONENT_VIEW.rawValue, default: 0], 1)
            XCTAssertEqual(counts[OMNI_RENDER_ACTIVITY.rawValue, default: 0], 1)
            let bytes = try output()
            let started = DispatchTime.now().uptimeNanoseconds
            fixture.text.ingest(wire: bytes)
            XCTAssertTrue(surface.apply(bytes, text: fixture.text))
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        durations.sort()
        print(
            "Shell T8 expanded media MainActor ingest+apply ms: p50=\(durations[128]) p95=\(durations[243]) samples=256 target=1.0"
        )
    }

    func testIslandIntentUsesNativeFeedbackAndBoundaryHandlers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture(source: source(in: root))
        configure(fixture, notch: true)
        try fixture.render()
        func primary() throws -> omni_wire_node {
            try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 })
        }
        let compact = try primary()
        XCTAssertGreaterThan(compact.press_scale, 0)
        XCTAssertEqual(compact.press_action, 0)
        XCTAssertGreaterThan(compact.hover_delay, 0)
        XCTAssertEqual(compact.input_flags & UInt8(OMNI_INPUT_FOCUSABLE), UInt8(OMNI_INPUT_FOCUSABLE))
        XCTAssertEqual(fixture.text.string(compact.keys), "escape\nleft\nright")
        fixture.invoke(compact.hover_action, event: intentEvent("began"))
        try fixture.render()
        XCTAssertGreaterThan(try primary().height, compact.height)
        XCTAssertTrue(fixture.captions.contains("Test track"))
        fixture.invoke(try primary().hover_action, event: intentEvent("ended"))
        try fixture.render()
        XCTAssertEqual(try primary().height, compact.height)
        fixture.invoke(try primary().action)
        try fixture.render()
        let expanded = try primary()
        XCTAssertEqual(expanded.input_flags & UInt8(OMNI_INPUT_FOCUSABLE), UInt8(OMNI_INPUT_FOCUSABLE))
        XCTAssertEqual(expanded.input_flags & UInt8(OMNI_INPUT_GESTURE_ALL), 0)
        XCTAssertEqual(expanded.gesture_source, 2)
        XCTAssertEqual(expanded.gesture_direction, 3)
        XCTAssertGreaterThan(expanded.gesture_commit_distance, 0)
        XCTAssertGreaterThan(expanded.gesture_commit_velocity, 0)
        XCTAssertEqual(fixture.text.string(expanded.keys), "escape\nleft\nright")
        fixture.invoke(expanded.key_action, event: intentEvent("down", key: "right"))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Design review"))
        fixture.invoke(try primary().key_action, event: intentEvent("down", key: "escape"))
        try fixture.render()
        XCTAssertEqual(try primary().height, compact.height)
        fixture.invoke(try primary().action)
        try fixture.render()
        fixture.invoke(try primary().gesture_action, event: intentEvent("ended", committed: false))
        try fixture.render()
        XCTAssertEqual(try primary().height, expanded.height)
        fixture.invoke(try primary().gesture_action, event: intentEvent("ended", committed: true))
        try fixture.render()
        XCTAssertEqual(try primary().height, compact.height)
        fixture.invoke(try primary().action)
        try fixture.render()
        fixture.invoke(try primary().outside_press_action)
        try fixture.render()
        XCTAssertEqual(try primary().height, compact.height)
    }

    func testMotionRecipesCoverModesPromotionContentAndNativeSwipe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture(source: source(in: root))
        configure(fixture, notch: true)
        try fixture.render()
        func primary() throws -> omni_wire_node {
            try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 })
        }
        func spring(_ node: omni_wire_node, response: Double, bounce: Double) throws {
            XCTAssertNotEqual(node.motion, 0)
            XCTAssertEqual(node.motion_curve, 255)
            let fields = fixture.text.string(node.motion_curve_ref).split(separator: ":")
            XCTAssertEqual(fields.count, 3)
            XCTAssertEqual(fields.first, "spring")
            guard fields.count == 3 else { return }
            XCTAssertEqual(try XCTUnwrap(Double(fields[1])), response, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(Double(fields[2])), bounce, accuracy: 0.000001)
        }
        let compact = try primary()
        try spring(compact, response: 0.30, bounce: 0.04)
        XCTAssertTrue(fixture.nodes.contains { $0.appear != 0 && $0.exit != 0 })
        fixture.invoke(compact.hover_action, event: intentEvent("began"))
        try fixture.render()
        try spring(try primary(), response: 0.28, bounce: 0.12)
        let preview = try XCTUnwrap(fixture.nodes.first { fixture.text.string($0.text) == "Test track" })
        XCTAssertNotEqual(preview.appear, 0)
        XCTAssertNotEqual(preview.exit, 0)
        fixture.invoke(try primary().action)
        try fixture.render()
        let expanded = try primary()
        try spring(expanded, response: 0.38, bounce: 0.18)
        XCTAssertNotEqual(expanded.gesture_track, 0)
        XCTAssertEqual(expanded.input_flags & UInt8(OMNI_INPUT_GESTURE_ALL), 0)
        let track = try XCTUnwrap(ShellGestureTrack(fixture.text.string(expanded.gesture_track)))
        XCTAssertEqual(track.dy.to, -40)
        XCTAssertEqual(track.dy.rubber, 0.4, accuracy: 0.000001)
        XCTAssertEqual(track.scale.to, 0.94, accuracy: 0.000001)
        fixture.invoke(expanded.key_action, event: intentEvent("down", key: "right"))
        try fixture.render()
        try spring(try primary(), response: 0.34, bounce: 0.16)
        XCTAssertTrue(fixture.captions.contains("Design review"))
        fixture.invoke(try primary().gesture_action, event: intentEvent("ended", committed: true))
        try fixture.render()
        try spring(try primary(), response: 0.30, bounce: 0.04)
    }

    func testProfileColorsTargetsAndDirectionalSwipeStayInPublicLuau() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture(source: source(in: root))
        configure(fixture, notch: true)
        fixture.set("settings") { writer in
            writer.map(7)
            writer.key("backgroundColor")
            writer.string("#112233")
            writer.key("highlightColor")
            writer.string("#33669988")
            writer.key("clickTarget")
            writer.string("expand")
            writer.key("rightClickTarget")
            writer.string("component:agenda")
            writer.key("swipeTarget")
            writer.string("next")
            writer.key("swipeDirection")
            writer.string("right")
            writer.key("swipeDistance")
            writer.number(80)
        }
        try fixture.render()
        func primary() throws -> omni_wire_node {
            try XCTUnwrap(fixture.nodes.first { $0.hover_action != 0 })
        }
        XCTAssertEqual(try primary().fill, 0x112233FF)
        fixture.invoke(try primary().action)
        try fixture.render()
        let expanded = try primary()
        XCTAssertEqual(expanded.gesture_direction, 2)
        XCTAssertEqual(expanded.gesture_commit_distance, 80)
        XCTAssertEqual(expanded.input_flags & UInt8(OMNI_INPUT_GESTURE_ALL), 0)
        let track = try XCTUnwrap(ShellGestureTrack(fixture.text.string(expanded.gesture_track)))
        XCTAssertEqual(track.dx.to, 40)
        XCTAssertEqual(track.dy.to, 0)
        XCTAssertTrue(fixture.nodes.contains { $0.fill == 0x33669988 })
        fixture.invoke(expanded.secondary_action)
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Design review"))
        fixture.invoke(try primary().gesture_action, event: intentEvent("changed", committed: true))
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Design review"))
        fixture.invoke(try primary().gesture_action, event: intentEvent("ended", committed: true))
        try fixture.render()
        XCTAssertFalse(fixture.captions.contains("Design review"))

        fixture.set("settings") { writer in
            writer.map(4)
            writer.key("backgroundColor")
            writer.string("bad color")
            writer.key("clickTarget")
            writer.string("none")
            writer.key("rightClickTarget")
            writer.string("none")
            writer.key("swipeTarget")
            writer.string("none")
        }
        try fixture.render()
        let disabled = try primary()
        XCTAssertEqual(disabled.fill, 0x000000FF)
        XCTAssertEqual(disabled.action, 0)
        XCTAssertEqual(disabled.secondary_action, 0)
        XCTAssertEqual(disabled.gesture_action, 0)
        XCTAssertEqual(disabled.gesture_track, 0)
        XCTAssertTrue(fixture.nodes
            .contains { fixture.text.string($0.help) == "Add and customize island widgets" && $0.action != 0 })
    }

    func testOrdinaryBarPlacementDoesNotAcquireIslandInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture(source: source(in: root))
        configure(fixture, notch: false)
        fixture.set("island") { $0.null() }
        try fixture.render()
        XCTAssertTrue(fixture.nodes.allSatisfy {
            $0.hover_action == 0 && $0.gesture_action == 0 && $0.key_action == 0 && $0.outside_press_action == 0
                && $0.input_flags & UInt8(OMNI_INPUT_FOCUSABLE) == 0
        })
    }

    func testSolidLakeCapsulePixelsSurviveNativeHoverFocusAndPress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(in: root)
        for scale in [CGFloat(1), 2] {
            for (color, rgb) in [("#000000", [UInt8(0), 0, 0]), ("#112233", [UInt8(17), 34, 51])] {
                let fixture = try Fixture(source: source)
                configure(fixture, notch: true)
                fixture.set("settings") { writer in
                    writer.map(1)
                    writer.key("backgroundColor")
                    writer.string(color)
                }
                try fixture.render()
                let surface = lakeSurface(source, scale: scale)
                defer { surface.setVisible(false) }
                try applyLake(fixture, to: surface)
                let primary = try XCTUnwrap(surface.layout.core.elements { $0.focusable }.first)
                surface.focusDeclared(primary)
                fixture.invoke(surface.layout.core.content(of: primary).action)
                try fixture.render()
                try applyLake(fixture, to: surface)
                let frame = CGRect(surface.layout.core.absoluteFrame(of: primary))
                XCTAssertEqual(frame.width, 520)
                let point = CGPoint(x: frame.midX, y: frame.maxY - 12)
                func check(_ state: String) throws {
                    let image = try lakeRaster(surface, scale: scale)
                    let data = try XCTUnwrap(image.dataProvider?.data)
                    let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
                    let offset = Int(point.y * scale) * image.bytesPerRow + Int(point.x * scale) * 4
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + offset, count: 4)), rgb + [255], state)
                }
                try check("expanded with declared focus")
                surface.hover(at: point)
                try check("hovered solid capsule")
                surface.press(at: point)
                try check("pressed solid capsule")
                surface.release(at: point)
                surface.hover(at: nil)
                try check("pointer left while declared focus remains")
            }
        }
    }

    func testLakeWidgetsButtonOpensVisibleSettingsAndExportsRenderedStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(in: root)
        let config = ShellConfig.resolve(shellDirectory: root.appendingPathComponent("shell"))
        let entries = try ShellComponentCatalog.installed(directories: config.directories)
        XCTAssertEqual(entries.count, 14)
        XCTAssertTrue(entries.allSatisfy { $0.error == nil && $0.descriptor != nil })
        let settings = try XCTUnwrap(ShellRootSettings.load("lake", directories: config.directories))
        let catalog = try ShellComponentCatalog.catalogBytes(entries)
        let schema = try ShellComponentCatalog.settingsBytes(settings.options)
        for notch in [false, true] {
            let fixture = try Fixture(source: source)
            configure(fixture, notch: notch)
            for (key, bytes) in [("catalog", catalog), ("settingsSchema", schema)] {
                XCTAssertEqual(bytes.withUnsafeBufferPointer {
                    omni_instance_set_value(fixture.instance, key, $0.baseAddress, $0.count)
                }, OMNI_OK)
            }
            let surface = lakeSurface(source, scale: 2)
            defer { surface.setVisible(false) }
            surface.onAction = { click in fixture.invoke(click.action, event: click.event.bytes) }
            let name = notch ? "notch" : "plain"
            try fixture.render()
            try applyLake(fixture, to: surface)
            try exportLake(surface, name: "lake-\(name)-compact", scale: 2)
            let primary = try XCTUnwrap(surface.layout.core.elements { $0.focusable }.first)
            let compact = CGRect(surface.layout.core.absoluteFrame(of: primary))
            let point = CGPoint(x: compact.midX, y: compact.midY)
            surface.press(at: point)
            surface.release(at: point)
            try fixture.render()
            try applyLake(fixture, to: surface)
            XCTAssertTrue(fixture.captions.contains("Widgets"))
            let control = try XCTUnwrap(surface.layout.core.elements {
                fixture.text.string($0.help) == "Add and customize island widgets" && $0.action != 0
            }.first)
            let button = CGRect(surface.layout.core.absoluteFrame(of: control))
            let expanded = CGRect(surface.layout.core.absoluteFrame(of: primary))
            XCTAssertTrue(expanded.contains(button), "The visible Widgets button must fit inside the capsule")
            surface.hover(at: CGPoint(x: expanded.midX, y: expanded.maxY - 12))
            try exportLake(surface, name: "lake-\(name)-expanded-hovered", scale: 2)
            let center = CGPoint(x: button.midX, y: button.midY)
            surface.press(at: center)
            surface.release(at: center)
            try fixture.render()
            try applyLake(fixture, to: surface)
            XCTAssertTrue(fixture.captions.contains("Your widgets"))
            XCTAssertTrue(fixture.captions.contains("Done"))
            XCTAssertTrue(fixture.nodes.contains { fixture.text.string($0.help) == "Add widget" && $0.action != 0 })
            try exportLake(surface, name: "lake-\(name)-widgets", scale: 2)
            let add = try XCTUnwrap(surface.layout.core.elements {
                fixture.text.string($0.help) == "Add widget" && $0.action != 0
            }.first)
            let addFrame = CGRect(surface.layout.core.absoluteFrame(of: add))
            let addPoint = CGPoint(x: addFrame.midX, y: addFrame.midY)
            surface.press(at: addPoint)
            surface.release(at: addPoint)
            try fixture.render()
            try applyLake(fixture, to: surface)
            XCTAssertTrue(fixture.captions.contains("Add a widget"))
            XCTAssertEqual(fixture.captions.filter { $0 == "Add" }.count, 12)
            XCTAssertFalse(fixture.captions.contains("Unavailable"))
            for entry in entries.prefix(12) {
                XCTAssertTrue(fixture.captions.contains(try XCTUnwrap(entry.descriptor).title))
            }
            try exportLake(surface, name: "lake-\(name)-add-widget", scale: 2)
        }
    }

    private func lakeSurface(_ source: ShellWidgetSource, scale: CGFloat) -> ShellWidgetSurface {
        let surface = ShellWidgetSurface(
            scale: scale, resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)), directories: []
        )
        surface.drawsRootMaterial = true
        surface.assetFolders = source.assetPackages
        return surface
    }

    private func applyLake(_ fixture: Fixture, to surface: ShellWidgetSurface) throws {
        var count = 0
        let output = try XCTUnwrap(omni_instance_output(fixture.instance, OMNI_VIEW_BAR, &count))
        XCTAssertTrue(surface.apply(Array(UnsafeBufferPointer(start: output, count: count)), text: fixture.text))
        surface.view.frame = CGRect(origin: .zero, size: surface.size)
    }

    private func lakeRaster(_ surface: ShellWidgetSurface, scale: CGFloat) throws -> CGImage {
        let layer = try XCTUnwrap(surface.view.layer)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(surface.size.width * scale)), height: Int(ceil(surface.size.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        ShellLayerScene.engineQueue.sync { layer.render(in: context) }
        return try XCTUnwrap(context.makeImage())
    }

    private func exportLake(_ surface: ShellWidgetSurface, name: String, scale: CGFloat) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        let image = try lakeRaster(surface, scale: scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let tile = Int(20 * scale)
        for y in stride(from: 0, to: image.height, by: tile) {
            for x in stride(from: 0, to: image.width, by: tile) {
                context.setFillColor(CGColor(gray: (x / tile + y / tile).isMultiple(of: 2) ? 0.20 : 0.28, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: tile, height: tile))
            }
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func intentEvent(_ phase: String, key: String? = nil, committed: Bool? = nil) -> [UInt8] {
        var event = ShellValueWriter()
        event.map(1 + (key == nil ? 0 : 1) + (committed == nil ? 0 : 1))
        event.key("phase")
        event.string(phase)
        if let key {
            event.key("key")
            event.string(key)
        }
        if let committed {
            event.key("committed")
            event.bool(committed)
        }
        return event.bytes
    }

    func testRenamingEveryComponentAndIDLeavesThePublicProfileOutputEquivalent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try source(in: root)
        let before = try Fixture(source: original)
        configure(before, notch: true)
        try before.render()
        let shell = root.appendingPathComponent("shell")
        let profile = shell.appendingPathComponent("lake")
        let configURL = profile.appendingPathComponent("shell.toml")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        for name in Set(original.components.map(\.widget)) {
            try FileManager.default.moveItem(
                at: profile.appendingPathComponent("widgets/\(name)"),
                to: profile.appendingPathComponent("widgets/zz-\(name)")
            )
            config = config.replacingOccurrences(of: "widget = \"\(name)\"", with: "widget = \"zz-\(name)\"")
        }
        for instance in original.components {
            config = config.replacingOccurrences(of: "id = \"\(instance.id)\"", with: "id = \"zz-\(instance.id)\"")
        }
        try Data(config.utf8).write(to: configURL)
        let renamed = try source(in: root, install: false)
        let after = try Fixture(source: renamed)
        configure(after, notch: true)
        try after.render()
        let expectedCaptions = before.captions.map { caption in
            for name in Set(original.components.map(\.widget)) {
                let prefix = "@omni-asset:\(name)/"
                if caption.hasPrefix(prefix) {
                    return "@omni-asset:zz-\(name)/" + caption.dropFirst(prefix.count)
                }
            }
            return caption
        }
        XCTAssertEqual(expectedCaptions, after.captions)
        XCTAssertEqual(before.nodes.map(\.width), after.nodes.map(\.width))
        XCTAssertEqual(before.nodes.map(\.height), after.nodes.map(\.height))
        XCTAssertEqual(before.nodes.map(\.fill), after.nodes.map(\.fill))
        XCTAssertEqual(renamed.components.filter { $0.widget == "zz-world-clock" }.count, 2)
    }

    func testStockWeatherAcceptsMissingOptionalFieldsAndClockInstancesKeepTheirOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try source(in: root)
        let custom = ShellWidgetSource(
            chunk: original.chunk,
            main: """
            function render(ctx)
                return ui.row{
                    ui.component{ id = "forecast", view = "expanded" },
                    ui.component{ id = "london", view = "expanded" },
                    ui.component{ id = "tokyo", view = "expanded" }
                }
            end
            """,
            modules: original.modules, moduleLimit: original.moduleLimit, components: original.components,
            componentDescriptors: original.componentDescriptors, assetPackages: original.assetPackages
        )
        let fixture = try Fixture(source: custom)
        configure(fixture, notch: false)
        fixture.set("weather") { ShellWeather(temp: 20, code: 0, day: true, unit: "°C").write(into: &$0) }
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("H —  L — · Humidity —"))
        XCTAssertTrue(fixture.captions.contains("London"))
        XCTAssertTrue(fixture.captions.contains("Tokyo"))
        XCTAssertTrue(fixture.captions.contains("20°C"))
        let clocks = fixture.nodes.filter { $0.text != 0 && $0.text_size == 4800 }
            .map { fixture.text.string($0.text) }.filter { $0.contains(":") }
        XCTAssertEqual(Set(clocks).count, 2)
    }

    private func source(in root: URL, install: Bool = true) throws -> ShellWidgetSource {
        let shell = root.appendingPathComponent("shell")
        if install {
            XCTAssertTrue(ShellDefaults.sync(into: shell).isEmpty)
            XCTAssertTrue(try ShellProfiles.select("lake", in: shell))
        }
        let host = ShellWidgetHost(
            configDirectory: root, resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        var problems: [String] = []
        host.config = ShellConfig.resolve(shellDirectory: shell, problems: &problems)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        return try host.widgetSource(of: ShellWidgetHost.WidgetState(
            name: "lake",
            sourceURL: XCTUnwrap(host.config.widget("lake"))
        ))
    }

    private func configure(_ fixture: Fixture, notch: Bool) {
        fixture.set("seconds") { $0.number(1_791_723_600) }
        fixture.set("battery") { $0.number(80) }
        fixture.set("charging") { $0.bool(false) }
        fixture.set("media") { writer in
            var media = ShellMedia()
            media.title = "Test track"
            media.artist = "Test artist"
            media.playing = true
            media.write(into: &writer)
        }
        fixture.set("calendar") { writer in
            ShellCalendar(access: "full", events: [ShellCalendarEvent(
                id: "one", title: "Design review", calendar: "Work", color: "#ff0000", start: 1_791_724_000,
                end: 1_791_725_000, allDay: false, location: "", time: "10:00", day: "Today"
            )], month: nil).write(into: &writer)
        }
        fixture.set("island") { writer in
            let monitor = Monitor(
                id: .init(displayId: 93000),
                displayId: 93000,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868),
                hasNotch: notch,
                notchRange: notch ? 630 ... 810 : nil,
                notchHeight: notch ? 32 : 0,
                name: "Test"
            )
            ShellIslandData(
                monitor: monitor,
                geometry: ShellIslandGeometry(
                    monitor: monitor,
                    size: CGSize(width: 760, height: 360)
                ),
                visible: true,
                fullscreen: false
            ).write(to: &writer)
        }
    }
}
