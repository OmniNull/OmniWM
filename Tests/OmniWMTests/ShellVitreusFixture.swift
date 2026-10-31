// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

struct VitreusLabel {
    let text: String
    let frame: CGRect
    let style: UInt32
}

struct VitreusRequest {
    let kind: omni_service_kind
    let owner: omni_owner_token
    let name: String
    let id: UInt64
    let revision: UInt64
    let seconds: Double
    let bytes: [UInt8]
    var cancelled = false

    var stored: ShellServiceValue? {
        try? ShellServiceValue.decode(bytes)
    }
}

@MainActor
enum VitreusFixture {
    static let primary = "Built-in Retina Display"
    static let secondary = "Studio Display"

    static func shell() throws -> URL {
        _ = try ShellFontFixture.fonts()
        let shell = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitreus-\(UUID().uuidString)/shell", isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("vitreus", in: shell))
        return shell
    }

    static func remove(_ shell: URL) {
        try? FileManager.default.removeItem(at: shell.deletingLastPathComponent())
    }

    static func config(_ shell: URL) throws -> ShellConfig {
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        return config
    }

    static func source(_ shell: URL, components: [ShellComponentInstance]? = nil) throws -> ShellWidgetSource {
        let config = try config(shell)
        let island = try XCTUnwrap(config.island)
        return try ShellWidgetSourceLoader.build(.init(
            name: island.root, shellDirectory: shell, sourceURL: XCTUnwrap(config.widget(island.root)),
            directories: config.directories, profile: config.profile, components: components ?? island.components
        ))
    }

    static func resources(_ shell: URL, animations: Bool = false) throws -> ShellResources {
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: animations))
        resources.palette.refresh(
            theme: try config(shell).theme, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua))
        )
        return resources
    }

    static func probe(_ shell: URL, _ main: String) throws -> ShellRenderedWidget {
        let source = try source(shell)
        return try ShellRenderedWidget(
            name: "probe", source: main, modules: source.modules, chunk: "@vitreus/widgets/probe/init.luau",
            memoryLimit: ShellWidgetPackage.memoryLimit, moduleLimit: source.moduleLimit
        )
    }

    static func monitor(
        _ name: String = primary, id: CGDirectDisplayID = 95100, width: CGFloat = 1920, height: CGFloat = 1080
    ) -> Monitor {
        Monitor(
            id: .init(displayId: id), displayId: id, frame: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: height - 32), hasNotch: false, name: name
        )
    }

    static func island(_ monitor: Monitor) -> ShellIslandData {
        ShellIslandData(
            monitor: monitor, geometry: ShellIslandGeometry(monitor: monitor, size: monitor.frame.size),
            visible: true, fullscreen: false
        )
    }

    static func bar(_ monitor: Monitor = monitor(), enabled: Bool = true) -> ShellBarData {
        ShellBarData(monitor: monitor.name, monitorId: IPCDisplayRef.identifier(monitor.id), barEnabled: enabled)
    }

    static func show(
        _ widget: ShellRenderedWidget, on monitor: Monitor = monitor(), bar data: ShellBarData? = nil,
        acknowledgement: UInt64 = 0
    ) {
        widget.set("seconds") { $0.number(Date().timeIntervalSince1970.rounded(.down)) }
        widget.set("island") { island(monitor).write(to: &$0) }
        widget.render(data ?? bar(monitor), acknowledgement: acknowledgement)
        widget.surface.view.frame = CGRect(origin: .zero, size: widget.surface.size)
    }

    static func grab(
        _ widget: ShellRenderedWidget,
        at start: CGPoint,
        to point: CGPoint,
        on monitor: Monitor = monitor()
    ) {
        let index = widget.events.count
        widget.surface.press(at: start, timestamp: 0)
        widget.surface.drag(to: point, screen: .zero, timestamp: 0.01)
        deliver(widget, from: index, on: monitor)
    }

    static func drop(_ widget: ShellRenderedWidget, at point: CGPoint, on monitor: Monitor = monitor()) {
        let index = widget.events.count
        widget.surface.release(at: point, timestamp: 0.02)
        deliver(widget, from: index, on: monitor)
    }

    static func drag(
        _ widget: ShellRenderedWidget,
        key name: String,
        by offset: CGVector,
        on monitor: Monitor = monitor()
    ) throws {
        let frame = try frame(widget, key: name)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: start.x + offset.dx, y: start.y + offset.dy)
        grab(widget, at: start, to: end, on: monitor)
        drop(widget, at: end, on: monitor)
    }

    static func open(_ widget: ShellRenderedWidget, on monitor: Monitor = monitor()) {
        show(widget, on: monitor)
        trigger(widget.instance, "desk-open", bar(monitor).monitorId)
        show(widget, on: monitor)
    }

    static func desk(
        _ shell: URL, components: [ShellComponentInstance]? = nil, monitor: Monitor = monitor(), scale: CGFloat = 2,
        animations: Bool = false
    ) throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(
            source: source(shell, components: components), scale: scale,
            resources: resources(shell, animations: animations)
        )
        open(widget, on: monitor)
        return widget
    }

    static func clocked(_ shell: URL, now: Int, seed: [String: [UInt8]] = [:]) throws -> ShellRenderedWidget {
        let source = try source(shell)
        let shim = "local clock=require('./clock') local os={time=function() return clock.now end}\n"
        let modules = source.modules.map { module -> ShellWidgetSource.Module in
            module.path
                .hasSuffix("lib/vitreus/focus.luau") ? .init(path: module.path, source: shim + module.source) : module
        } + [.init(path: "vitreus/lib/vitreus/clock.luau", source: "return {now=\(now)}")]
        let main = source.main + """

        local clock = require("../lib/vitreus/clock")
        local deskTrigger = trigger
        function trigger(ctx, event)
            if event.name == "clock" then clock.now = tonumber(event.value) return end
            deskTrigger(ctx, event)
        end
        """
        let widget = try ShellRenderedWidget(
            name: "vitreus", source: main, modules: modules, chunk: source.chunk, resources: resources(shell),
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders), memoryLimit: ShellWidgetPackage.memoryLimit,
            moduleLimit: source.moduleLimit
        )
        for (owner, bytes) in seed {
            self.seed(widget, owner, bytes)
        }
        widget.configure(ShellComponentCatalog.configurationBytes(
            instances: source.components, descriptors: source.componentDescriptors
        ))
        open(widget)
        return widget
    }

    static func saved(_ requests: [VitreusRequest], _ owner: String, _ key: String) -> ShellServiceValue? {
        requests.last { $0.kind == OMNI_SERVICE_STORE && $0.name.hasSuffix(owner) }?.stored?.fields?[key]
    }

    static func store(_ key: String, _ value: ShellServiceValue) -> [UInt8] {
        var writer = ShellValueWriter()
        ShellServiceValue.object([key: value]).write(to: &writer)
        return writer.bytes
    }

    static func commit(_ widget: ShellRenderedWidget, _ text: String) throws {
        let input = try XCTUnwrap(widget.tree().first { $0.kind == .input })
        var event = ShellEvent()
        event.text = text
        widget.invoke(input.content.inputCommitAction, event: event)
        show(widget)
    }

    static func event(_ name: String, _ value: String?, source: String? = nil) -> [UInt8] {
        var writer = ShellValueWriter()
        writer.map(source == nil ? 2 : 3)
        writer.key("name")
        writer.string(name)
        writer.key("value")
        if let value { writer.string(value) } else { writer.null() }
        if let source {
            writer.key("source")
            writer.string(source)
        }
        return writer.bytes
    }

    static func trigger(_ instance: OpaquePointer, _ name: String, _ value: String?, source: String? = nil) {
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(event(name, value, source: source).withUnsafeBufferPointer {
            omni_instance_trigger(instance, $0.baseAddress, $0.count, 25_000_000, &error, error.count)
        }, OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    static func seed(_ widget: ShellRenderedWidget, _ owner: String, _ bytes: [UInt8]) {
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(bytes.withUnsafeBufferPointer {
            omni_vm_seed_store(
                widget.vm,
                owner,
                owner.utf8.count,
                $0.baseAddress,
                $0.count,
                nil,
                0,
                &error,
                error.count
            )
        }, OMNI_OK)
    }

    static func drain(_ widget: ShellRenderedWidget) -> [VitreusRequest] {
        var request = omni_service_request()
        var result: [VitreusRequest] = []
        while omni_vm_next_service(widget.vm, &request) {
            result.append(VitreusRequest(
                kind: request.kind, owner: request.owner,
                name: request.owner_name.map {
                    String(decoding: UnsafeRawBufferPointer(start: $0, count: request.owner_name_length), as: UTF8.self)
                } ?? "",
                id: request.id, revision: request.revision, seconds: request.seconds,
                bytes: request.value.map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? [],
                cancelled: request.cancelled
            ))
        }
        for store in result where store.kind == OMNI_SERVICE_STORE { complete(widget, store) }
        return result
    }

    static func complete(_ widget: ShellRenderedWidget, _ request: VitreusRequest) {
        var writer = ShellValueWriter()
        ShellServiceValue.object(["ok": .bool(true)]).write(to: &writer)
        var handled = false
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_vm_complete_service(
                widget.vm, request.owner, request.id, request.revision, $0.baseAddress, $0.count, 100_000_000,
                &handled, &error, error.count
            )
        }, OMNI_OK)
    }

    static func key(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        hash &= ~(UInt64(3) << 62)
        return hash == 0 ? 1 : hash
    }

    static func element(_ widget: ShellRenderedWidget, key name: String) throws -> ElementHandle {
        let layout = widget.surface.layout
        return try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.key(of: $0) == key(name) }, name)
    }

    static func frame(_ widget: ShellRenderedWidget, key name: String) throws -> CGRect {
        try CGRect(widget.surface.layout.core.absoluteFrame(of: element(widget, key: name)))
    }

    static func labels(_ widget: ShellRenderedWidget) -> [VitreusLabel] {
        let layout = widget.surface.layout
        return layout.core.elements { $0.text != 0 }.filter { layout.core.kind(of: $0) == .label }.map {
            VitreusLabel(
                text: widget.text.string(layout.core.content(of: $0).text),
                frame: CGRect(layout.core.absoluteFrame(of: $0)),
                style: layout.core.content(of: $0).style
            )
        }
    }

    static func click(_ widget: ShellRenderedWidget, at point: CGPoint, on monitor: Monitor = monitor()) {
        let before = widget.actions.count
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        for action in widget.actions.dropFirst(before) where action & OMNI_ACTION_HANDLER != 0 {
            widget.invoke(action)
        }
        show(widget, on: monitor)
    }

    static func click(_ widget: ShellRenderedWidget, key name: String, on monitor: Monitor = monitor()) throws {
        let frame = try frame(widget, key: name)
        click(widget, at: CGPoint(x: frame.midX, y: frame.midY), on: monitor)
    }
}

extension VitreusFixture {
    static func settings(_ widget: ShellRenderedWidget, _ values: [String: ShellComponentValue]) {
        widget.set("settings") { writer in
            writer.map(values.count)
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                writer.key(key)
                value.write(to: &writer)
            }
        }
    }

    static func body(_ widget: ShellRenderedWidget, key name: String = "desk-glass") throws -> ShellGlassBody {
        let slot = try element(widget, key: name).slot
        let scene = widget.surface.scene
        return try XCTUnwrap(ShellLayerScene.engineQueue.sync { scene.glassBodies[slot] }, name)
    }

    static func pixels(
        _ widget: ShellRenderedWidget, crop: CGRect, scale: Int, shadowless: Bool = false
    ) throws -> [UInt8] {
        let scene = widget.surface.scene
        let size = widget.surface.size
        return try ShellLayerScene.engineQueue.sync {
            try offscreen(scene, size: size, crop: crop, scale: scale, shadowless: shadowless)
        }
    }

    private nonisolated static func offscreen(
        _ scene: ShellLayerScene, size: CGSize, crop: CGRect, scale: Int, shadowless: Bool
    ) throws -> [UInt8] {
        let container = scene.container
        container.frame = CGRect(origin: .zero, size: size)
        let previous = container.superlayer
        let index = previous?.sublayers?.firstIndex(of: container) ?? 0
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: Int(crop.width) * scale, height: Int(crop.height) * scale)
        root.isGeometryFlipped = true
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.bounds = container.bounds
        holder.setAffineTransform(
            CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)).translatedBy(x: -crop.minX, y: -crop.minY)
        )
        root.addSublayer(holder)
        holder.addSublayer(container)
        let shadows = shadowless ? scene.glassBodies.values.compactMap(\.sdfLayers.first) : []
        for layer in shadows { layer.isHidden = true }
        defer {
            for layer in shadows { layer.isHidden = false }
            container.removeFromSuperlayer()
            previous?.insertSublayer(container, at: UInt32(index))
        }
        return try ShellOffscreenRenderer(root: root, width: Int(root.frame.width), height: Int(root.frame.height))
            .render()
    }

    static func deliver(_ widget: ShellRenderedWidget, from index: Int, on monitor: Monitor = monitor()) {
        for click in widget.events.dropFirst(index) where click.action & OMNI_ACTION_HANDLER != 0 {
            widget.invoke(click.action, event: click.event)
        }
        show(widget, on: monitor, acknowledgement: widget.invocation ?? 0)
    }
}
