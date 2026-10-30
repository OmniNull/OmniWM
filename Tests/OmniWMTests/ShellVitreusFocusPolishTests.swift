// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

private struct FocusTimer {
    let request: VitreusRequest
    let cancelled: Bool
}

@MainActor
private enum Focus {
    static func role(_ color: Color) -> (role: ShellRole?, alpha: Double) {
        (ShellRole(rawValue: Int(color.role & 0xFF) - 1), Double(color.role >> 8) / 255)
    }

    static func wave(_ frame: Double, _ frequency: Double, _ seed: Double) -> Double {
        sin((frame * frequency + seed) * .pi / 180)
    }

    static func head(_ path: String) -> CGPoint {
        let numbers = path.split(separator: " ").dropFirst().prefix(2).compactMap { Double($0) }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    static func slide(_ time: Double) -> Double {
        let frequency = 2 * Double.pi / 0.424
        let decay = (1 - 0.19) * frequency
        let damped = (frequency * frequency - decay * decay).squareRoot()
        return 1 - exp(-decay * time) * (cos(damped * time) + decay / damped * sin(damped * time))
    }

    static func bgra(_ bytes: [UInt8], crop: CGRect, scale: Int, _ point: CGPoint) -> [Int] {
        let width = Int(crop.width) * scale
        let row = Int((point.y - crop.minY) * CGFloat(scale))
        let index = (row * width + Int((point.x - crop.minX) * CGFloat(scale))) * 4
        return bytes[index ..< index + 4].map(Int.init)
    }

    nonisolated static func miterExcess(_ layer: CAShapeLayer, around centre: CGPoint, reach: CGFloat) throws -> Int {
        let path = try XCTUnwrap(layer.path)
        let join: CGLineJoin = switch layer.lineJoin {
        case .round: .round
        case .bevel: .bevel
        default: .miter
        }
        let cap: CGLineCap = switch layer.lineCap {
        case .round: .round
        case .square: .square
        default: .butt
        }
        let width = layer.lineWidth
        let drawn = path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: join, miterLimit: layer.miterLimit)
        let smooth = path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 0)
        let step = reach / 160
        var count = 0
        for row in stride(from: centre.y - reach, through: centre.y + reach, by: step) {
            for column in stride(from: centre.x - reach, through: centre.x + reach, by: step) {
                let point = CGPoint(x: column, y: row)
                if drawn.contains(point), !smooth.contains(point) { count += 1 }
            }
        }
        return count
    }

    static func export(_ bytes: [UInt8], crop: CGRect, scale: Int, name: String) throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil else { return }
        let width = Int(crop.width) * scale
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: Int(crop.height) * scale, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        try ShellVitreusDeskTests.write(image, name: name)
    }
}

@MainActor
final class ShellVitreusFocusPolishTests: XCTestCase {
    private let du = 1.242
    private let pitch = 58.0

    private func desk(scale: CGFloat = 2) throws -> ShellRenderedWidget {
        let shell = try VitreusFixture.shell()
        let folder = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try VitreusFixture.desk(shell, scale: scale)
    }

    private func animate(_ widget: ShellRenderedWidget) throws -> ShellOffscreenRenderer {
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(origin: .zero, size: widget.surface.size)
            root.speed = 0
            root.timeOffset = CACurrentMediaTime()
            return try ShellOffscreenRenderer(root: root, width: Int(root.frame.width), height: Int(root.frame.height))
        }
        widget.resources.motion.userAnimationsEnabled = true
        widget.surface.animates = true
        return renderer
    }

    private func has(_ widget: ShellRenderedWidget, _ key: String) -> Bool {
        let layout = widget.surface.layout
        return layout.core.elements { _ in true }.contains { layout.core.key(of: $0) == VitreusFixture.key(key) }
    }

    private func paint(_ widget: ShellRenderedWidget, _ key: String) throws -> Paint {
        try widget.surface.layout.core.paint(of: VitreusFixture.element(widget, key: key))
    }

    private func content(_ widget: ShellRenderedWidget, _ key: String) throws -> Content {
        try widget.surface.layout.core.content(of: VitreusFixture.element(widget, key: key))
    }

    private func recipe(_ widget: ShellRenderedWidget, _ key: String) throws -> ShellGlassRecipe {
        try XCTUnwrap(ShellGlassRecipe(widget.text.string(content(widget, key).text)), key)
    }

    private func morph(_ widget: ShellRenderedWidget, _ key: String) throws -> ShellMorphRecipe {
        try XCTUnwrap(ShellMorphRecipe(widget.text.string(paint(widget, key).morph)), key)
    }

    private func strokes(_ widget: ShellRenderedWidget, _ key: String) throws -> [String] {
        try (1 ... 2).map { try widget.text.string(content(widget, "\(key)-\($0)").text) }
    }

    private func hover(_ widget: ShellRenderedWidget, _ key: String, _ phase: ShellEvent.Phase) throws {
        let action = try content(widget, key).hoverAction
        XCTAssertNotEqual(action, 0, key)
        var event = ShellEvent()
        event.phase = phase
        widget.invoke(action, event: event)
        VitreusFixture.show(widget)
    }

    private func click(_ widget: ShellRenderedWidget, _ key: String) throws {
        widget.invoke(try content(widget, key).action)
        VitreusFixture.show(widget)
    }

    private func timers(_ widget: ShellRenderedWidget) -> [FocusTimer] {
        var request = omni_service_request()
        var timers: [FocusTimer] = []
        while omni_vm_next_service(widget.vm, &request) {
            let entry = VitreusRequest(
                kind: request.kind, owner: request.owner, name: "", id: request.id, revision: request.revision,
                seconds: request.seconds, bytes: []
            )
            if request.kind == OMNI_SERVICE_TIMER {
                timers.append(FocusTimer(request: entry, cancelled: request.cancelled))
            } else if request.kind == OMNI_SERVICE_STORE {
                VitreusFixture.complete(widget, entry)
            }
        }
        return timers
    }

    func testTheChipThumbIsAFlatMintBodyWithVitreusEdgeSpringsAndATrackedPencilOutline() throws {
        let widget = try desk()
        let thumb = try recipe(widget, "chip-thumb")
        XCTAssertTrue(thumb.flat)
        XCTAssertEqual(thumb.rim, 0.16, accuracy: 1e-6)
        XCTAssertEqual(thumb.blend, 0)
        XCTAssertEqual(thumb.shadowOffset, .zero)
        let body = try paint(widget, "chip-thumb")
        XCTAssertEqual(Focus.role(body.fill).role, .accent)
        XCTAssertEqual(Focus.role(body.fill).alpha, 1, accuracy: 0.003)
        XCTAssertEqual(Focus.role(body.shadow).role, .accent)
        XCTAssertEqual(Focus.role(body.shadow).alpha, 0.42, accuracy: 0.003)
        XCTAssertEqual(Double(body.shadowRadius), 9 * du, accuracy: 1e-4)
        XCTAssertFalse(body.gradientSpecified)
        let chip = try VitreusFixture.frame(widget, key: "chip-30")
        let shape = try VitreusFixture.frame(widget, key: "chip-thumb-shape")
        XCTAssertEqual(shape.midX, chip.midX, accuracy: 0.01)
        XCTAssertEqual(shape.midY, chip.midY, accuracy: 0.01)
        XCTAssertEqual(shape.width, 52 * du, accuracy: 0.01)
        XCTAssertEqual(shape.height, 24 * du, accuracy: 0.01)
        XCTAssertEqual(Double(try paint(widget, "chip-thumb-shape").cornerRadius), 10 * du, accuracy: 1e-4)
        let edges = try XCTUnwrap(morph(widget, "chip-thumb-shape").edges)
        XCTAssertEqual(edges.lead.response, 0.378, accuracy: 1e-6)
        XCTAssertEqual(edges.lead.bounce, 0.19, accuracy: 1e-6)
        XCTAssertEqual(edges.trail.response, 0.472, accuracy: 1e-6)
        XCTAssertEqual(edges.trail.bounce, 0.19, accuracy: 1e-6)
        XCTAssertEqual(edges.thin, 3.0 / 24, accuracy: 1e-6)
        XCTAssertEqual(edges.unit, 8 * du, accuracy: 1e-4)
        for index in 1 ... 2 {
            XCTAssertEqual(
                try morph(widget, "chip-thumb-outline-\(index)").track, VitreusFixture.key("chip-thumb-shape")
            )
        }
        XCTAssertEqual(try content(widget, "chip-30").hoverAction, 0)
    }

    func testChipThumbStretchesAlongItsTravelAsVitreusDoesAndLandsOnTheChosenChip() throws {
        for (target, slots) in [("chip-60", 2.0), ("chip-15", -1.0)] {
            let widget = try desk(scale: 1)
            let renderer = try animate(widget)
            defer { withExtendedLifetime(renderer) {} }
            let start = try VitreusFixture.frame(widget, key: "chip-thumb-shape")
            try click(widget, target)
            let destination = try VitreusFixture.frame(widget, key: target)
            let slot = try VitreusFixture.element(widget, key: "chip-thumb-shape").slot
            let outline = try VitreusFixture.element(widget, key: "chip-thumb-outline-1").slot
            let scene = widget.surface.scene
            let rest = 52 * du
            try ShellLayerScene.engineQueue.sync {
                let entry = try XCTUnwrap(scene.shapeTracks.entries[slot], target)
                XCTAssertNotNil(entry.edges, target)
                let origin = entry.terminal.rect.midX - (destination.midX - start.midX)
                var peak = (excess: 0.0, height: 0.0)
                for step in 0 ... 160 {
                    let time = Double(step) * 0.005
                    let rect = entry.shape(at: entry.begin + time).rect
                    let vitreus = origin + slots * pitch * du * Focus.slide(time)
                    XCTAssertEqual(rect.midX, vitreus, accuracy: 0.3 * abs(slots) * du, "\(target) \(time)")
                    if rect.width - rest > peak.excess { peak = (rect.width - rest, rect.height) }
                }
                XCTAssertEqual(peak.excess, 8 * abs(slots) * du, accuracy: 0.25 * abs(slots) * du, target)
                XCTAssertEqual(peak.height, 21 * du, accuracy: 0.2 * du, target)
                XCTAssertEqual(entry.terminal.rect.width, rest, accuracy: 0.01, target)
                XCTAssertEqual(entry.terminal.rect.height, 24 * du, accuracy: 0.01, target)
                XCTAssertNotNil(scene.layers[outline]?.animation(forKey: ShellLayerScene.pathTrackKey), target)
            }
            let landed = try VitreusFixture.frame(widget, key: "chip-thumb-shape")
            XCTAssertEqual(landed.midX, destination.midX, accuracy: 0.01, target)
        }
    }

    func testRestOutlinesAreVitreusPencilPillsAndOnlyStartAndResetBoil() throws {
        let widget = try desk()
        let chips = try strokes(widget, "chips-outline")
        let first = Focus.head(chips[0])
        XCTAssertEqual(first.x, 16 * du + 0.18 * du * Focus.wave(0, 57, 71000), accuracy: 0.002)
        XCTAssertEqual(first.y, 0.18 * du * Focus.wave(0, 62, 71060), accuracy: 0.002)
        let shifted = Focus.head(chips[1])
        XCTAssertEqual(shifted.x, 16.35 * du + 0.18 * du * Focus.wave(0, 72, 72300), accuracy: 0.002)
        XCTAssertEqual(shifted.y, 0.28 * du + 0.18 * du * Focus.wave(0, 77, 72360), accuracy: 0.002)
        for (index, width, alpha) in [(1, 1.3, 0.6), (2, 0.9, 0.2)] {
            let stroke = try paint(widget, "chips-outline-\(index)")
            XCTAssertEqual(Double(stroke.strokeWidth), width * du, accuracy: 1e-4)
            XCTAssertEqual(Focus.role(stroke.stroke).role, .foreground)
            XCTAssertEqual(Focus.role(stroke.stroke).alpha, alpha, accuracy: 0.003)
        }
        let rest = try ["start", "reset"].map { try strokes(widget, "\($0)-outline") }
        XCTAssertEqual(Focus.head(rest[0][0]).x, 14 * du + 0.18 * du * Focus.wave(0, 57, 71000), accuracy: 0.002)
        XCTAssertTrue(timers(widget).isEmpty)
        let idle = omni_vm_service_stats(widget.vm).reserved
        for (key, resting) in zip(["start", "reset"], rest) {
            try hover(widget, key, .began)
            let armed = timers(widget)
            XCTAssertEqual(armed.map(\.request.seconds), [0.2], key)
            XCTAssertEqual(armed.map(\.cancelled), [false], key)
            let hovered = try strokes(widget, "\(key)-outline")
            XCTAssertEqual(Focus.head(hovered[0]).x, 14 * du + 0.43 * du * Focus.wave(1, 57, 71000), accuracy: 0.002)
            XCTAssertEqual(Focus.head(hovered[0]).y, 0.43 * du * Focus.wave(1, 62, 71060), accuracy: 0.002)
            XCTAssertEqual(try strokes(widget, "chips-outline"), chips, key)
            VitreusFixture.complete(widget, try XCTUnwrap(armed.first).request)
            VitreusFixture.show(widget)
            XCTAssertEqual(timers(widget).map(\.cancelled), [false], key)
            let boiled = try strokes(widget, "\(key)-outline")
            XCTAssertEqual(Focus.head(boiled[0]).x, 14 * du + 0.43 * du * Focus.wave(2, 57, 71000), accuracy: 0.002)
            XCTAssertNotEqual(boiled, hovered, key)
            XCTAssertEqual(omni_vm_service_stats(widget.vm).reserved, idle + 1, key)
            try hover(widget, key, .ended)
            XCTAssertEqual(timers(widget).map(\.cancelled), [true], key)
            XCTAssertEqual(omni_vm_service_stats(widget.vm).reserved, idle, key)
            XCTAssertEqual(try strokes(widget, "\(key)-outline"), resting, key)
            VitreusFixture.show(widget)
            XCTAssertTrue(timers(widget).isEmpty, key)
        }
    }

    func testTheBoilStopsWithinTwoFramesWhenTheDeskClosesUnderTheHoveredStartButton() throws {
        let widget = try desk()
        let rest = try strokes(widget, "start-outline")
        let idle = omni_vm_service_stats(widget.vm).reserved
        let frame = try VitreusFixture.frame(widget, key: "start")
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let began = widget.events.count
        widget.surface.pointer = point
        widget.surface.updateHoverIntent(at: point)
        VitreusFixture.deliver(widget, from: began)
        var pending = timers(widget)
        XCTAssertEqual(pending.map(\.cancelled), [false])
        XCTAssertEqual(Double(try paint(widget, "start-glass").shadowRadius), 14 * du, accuracy: 1e-4)
        XCTAssertEqual(omni_vm_service_stats(widget.vm).reserved, idle + 1)
        VitreusFixture.trigger(widget.instance, "desk-close", nil)
        VitreusFixture.show(widget)
        XCTAssertFalse(has(widget, "start"))
        var ticks = 0
        while let tick = pending.first(where: { !$0.cancelled }), ticks < 3 {
            ticks += 1
            VitreusFixture.complete(widget, tick.request)
            VitreusFixture.show(widget)
            pending = timers(widget)
        }
        XCTAssertEqual(ticks, 2)
        XCTAssertEqual(omni_vm_service_stats(widget.vm).reserved, idle)
        VitreusFixture.open(widget)
        XCTAssertEqual(Double(try paint(widget, "start-glass").shadowRadius), 8 * du, accuracy: 1e-4)
        XCTAssertEqual(try strokes(widget, "start-outline"), rest)
        XCTAssertTrue(timers(widget).isEmpty)
    }

    func testStartIsAFlatMinthiToMintloBodyWithAFifthRimAndAZoneSpringGlow() throws {
        let widget = try desk(scale: 1)
        let start = try recipe(widget, "start-glass")
        XCTAssertTrue(start.flat)
        XCTAssertEqual(start.rim, 0.2, accuracy: 1e-6)
        XCTAssertEqual(start.gradientAngle, 90)
        XCTAssertEqual(start.shadowOffset, .zero)
        let body = try paint(widget, "start-glass")
        XCTAssertTrue(body.gradientSpecified)
        XCTAssertEqual(Focus.role(body.gradientFrom).role, .secondaryContainerForeground)
        XCTAssertEqual(Focus.role(body.gradientTo).role, .accent)
        let button = try VitreusFixture.frame(widget, key: "start")
        for key in ["start-glass", "start-glass-shape"] {
            XCTAssertEqual(try VitreusFixture.frame(widget, key: key), button, key)
        }
        XCTAssertEqual(Double(try paint(widget, "start-glass-shape").cornerRadius), 14 * du, accuracy: 1e-4)
        XCTAssertEqual(try content(widget, "start").pressScale, 0.94, accuracy: 1e-6)
        let glass = try VitreusFixture.element(widget, key: "start-glass")
        let surface = widget.surface
        guard case let .spring(response, bounce)? = surface.animation(for: glass)?.motion else {
            return XCTFail("the Start glass has no spring")
        }
        XCTAssertEqual(response, 2 * .pi * 0.14 / 6.64, accuracy: 1e-6)
        XCTAssertEqual(bounce, 0)
        let renderer = try animate(widget)
        defer { withExtendedLifetime(renderer) {} }
        try hover(widget, "start", .began)
        let radius = try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(surface.scene.glassBodies[glass.slot]?.sdfLayers.first)
            return (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
                .first { $0.keyPath?.hasSuffix("radius") == true }
        }
        let glow = try XCTUnwrap(radius, "the Start glow radius does not ease")
        XCTAssertEqual(try XCTUnwrap(glow.fromValue as? NSNumber).doubleValue, 8 * du, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(glow.toValue as? NSNumber).doubleValue, 14 * du, accuracy: 1e-3)
        XCTAssertEqual(glow.stiffness, pow(6.64 / 0.14, 2), accuracy: 1)
        XCTAssertEqual(glow.damping, 2 * 6.64 / 0.14, accuracy: 0.1)
    }

    func testFocusButtonsAndThumbRenderTheirVitreusColoursAndGlowAtOneAndTwoX() throws {
        let du = self.du
        for scale in [1, 2] {
            let widget = try desk(scale: CGFloat(scale))
            let (rect, _) = ShellVitreusDeskTests.envelope(width: 1920, height: 1080)
            let crop = rect.insetBy(dx: -24, dy: -24).integral
            let button = try VitreusFixture.frame(widget, key: "start")
            let thumb = try VitreusFixture.frame(widget, key: "chip-thumb-shape")
            let glass = CGPoint(x: rect.midX + 140 * du, y: button.minY - 3 * du)
            func sample(_ bytes: [UInt8], _ point: CGPoint) -> [Int] {
                Focus.bgra(bytes, crop: crop, scale: scale, point)
            }
            let resting = try VitreusFixture.pixels(widget, crop: crop, scale: scale)
            for (fraction, from, to) in [(0.25, [0xEC, 0xF8, 0xDC], [0xBD, 0xD6, 0x9E])] {
                let top = sample(resting, CGPoint(x: button.minX + 12 * du, y: button.minY + fraction * button.height))
                let bottom = sample(resting, CGPoint(
                    x: button.minX + 12 * du, y: button.minY + (1 - fraction) * button.height
                ))
                for channel in 0 ..< 3 {
                    let span = Double(to[channel] - from[channel])
                    XCTAssertEqual(Double(top[channel]), Double(from[channel]) + fraction * span, accuracy: 3)
                    XCTAssertEqual(Double(bottom[channel]), Double(to[channel]) - fraction * span, accuracy: 3)
                }
                XCTAssertEqual(top[3], 255)
            }
            let mint = sample(resting, CGPoint(x: thumb.minX + 4 * du, y: thumb.midY - 6 * du))
            for (channel, value) in [0xBD, 0xD6, 0x9E, 0xFF].enumerated() {
                XCTAssertEqual(mint[channel], value, accuracy: 3, "\(scale)x thumb")
            }
            let halo = { (bytes: [UInt8], gap: Double) in
                sample(bytes, CGPoint(x: button.midX + 30 * du, y: button.minY - gap * du))[1]
            }
            let base = sample(resting, glass)[1]
            XCTAssertGreaterThan(halo(resting, 3), base + 8, "\(scale)x rest glow")
            try Focus.export(resting, crop: crop, scale: scale, name: "vitreus-focus-polish-\(scale)x")
            try hover(widget, "start", .began)
            let hovered = try VitreusFixture.pixels(widget, crop: crop, scale: scale)
            XCTAssertGreaterThan(halo(hovered, 3), halo(resting, 3), "\(scale)x hover glow")
            XCTAssertGreaterThan(halo(hovered, 9), halo(resting, 9), "\(scale)x hover reach")
            try Focus.export(hovered, crop: crop, scale: scale, name: "vitreus-focus-polish-start-hover-\(scale)x")
        }
    }
}

extension ShellVitreusFocusPolishTests {
    func testBoiledOutlinesAreOpenPencilStrokesWithNoMiterSpikeWhereTheirEndsMeet() throws {
        let widget = try desk()
        try hover(widget, "reset", .began)
        for _ in 1 ..< 15 {
            VitreusFixture.complete(widget, try XCTUnwrap(timers(widget).first { !$0.cancelled }).request)
            VitreusFixture.show(widget)
        }
        let boiled = try strokes(widget, "reset-outline")
        XCTAssertEqual(Focus.head(boiled[0]).x, 14 * du + 0.43 * du * Focus.wave(15, 57, 71000), accuracy: 0.002)
        let scene = widget.surface.scene
        for (index, stroke) in boiled.enumerated() {
            let key = "reset-outline-\(index + 1)"
            XCTAssertFalse(try XCTUnwrap(ShellPath.parse(stroke)).elements.contains(.close), key)
            let slot = try VitreusFixture.element(widget, key: key).slot
            let excess = try ShellLayerScene.engineQueue.sync {
                try Focus.miterExcess(
                    XCTUnwrap(scene.layers[slot] as? CAShapeLayer), around: CGPoint(x: 14 * du, y: 0), reach: 8 * du
                )
            }
            XCTAssertEqual(excess, 0, key)
        }
    }
}
