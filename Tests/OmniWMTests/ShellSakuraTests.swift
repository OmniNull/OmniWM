// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
import IOSurface
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellSakuraTests: XCTestCase {
    private var shell: URL!
    private var config: ShellConfig!

    override func setUp() async throws {
        shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("sakura", in: shell))
        var problems: [String] = []
        config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shell)
    }

    func testProfileInstallsPetalsOnlyInsideShellSurfacesAndKeepsItsLightPalette() throws {
        XCTAssertEqual(config.profile, "sakura")
        XCTAssertEqual(config.themeName, "sakura")
        XCTAssertEqual(config.theme.light, config.theme.dark)
        XCTAssertEqual(
            config.leading,
            ["apple-menu", "app-menu", "omniwm", "workspaces", "scratchpads", "active-window"]
        )
        XCTAssertEqual(config.center, ["clock"])
        XCTAssertEqual(config.trailing, ["privacy", "media", "wifi", "battery-details", "control-center"])
        XCTAssertEqual(config.barOverride?.settings.height, 40)
        XCTAssertEqual(config.barOverride?.settings.fullWidth, true)
        XCTAssertEqual(config.barOverride?.settings.reserveLayoutSpace, true)
        XCTAssertNil(config.island)
        XCTAssertEqual(config.barShader, ShellBarShader(
            source: "sakura-petals.metal", fps: 30, values: SIMD4(0.55, 1, 10, 0)
        ))
        XCTAssertEqual(
            config.widget("effects-lab"), shell.appendingPathComponent("default/widgets/effects-lab/init.luau")
        )
        let styled = shell.appendingPathComponent("sakura/widgets")
        let names = try FileManager.default.contentsOfDirectory(atPath: styled.path)
        XCTAssertEqual(names.count, 22)
        XCTAssertFalse(names.contains("focus-ribbon"))
        for name in names {
            XCTAssertEqual(config.widget(name), styled.appendingPathComponent("\(name)/init.luau"))
        }
    }

    func testPresetWidgetsFitBothOrientationsAndPopoutsContainTheirShader() async throws {
        for vertical in [false, true] {
            for name in config.leading + config.center + config.trailing {
                let rendered = try widget(name)
                rendered.render(bar(vertical: vertical))
                let size = rendered.surface.size
                XCTAssertGreaterThan(size.width, 0, name)
                XCTAssertGreaterThan(size.height, 0, name)
                XCTAssertLessThanOrEqual(vertical ? size.width : size.height, 40, name)
            }
        }
        for name in [
            "media",
            "wifi",
            "battery-details",
            "control-center",
            "volume",
            "calendar",
            "weather",
            "system-stats"
        ] {
            let rendered = try widget(name)
            rendered.render(bar())
            let shader = try XCTUnwrap(rendered.renderPopout().first { $0.kind == .shader }, name)
            XCTAssertEqual(rendered.text.string(shader.content.text), "sakura-petals.metal", name)
            XCTAssertEqual(shader.content.rate, 30, name)
            rendered.layoutPopout()
            let size = rendered.surface.size
            XCTAssertGreaterThan(size.width, 0, name)
            XCTAssertGreaterThan(size.height, 0, name)
            XCTAssertEqual(rendered.surface.chrome, ShellPopoutChrome(glass: false, clear: true, radius: 22), name)
            for element in rendered.surface.layout.core.elements(matching: { _ in true }) {
                let frame = CGRect(rendered.surface.layout.core.absoluteFrame(of: element))
                XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), name)
                XCTAssertGreaterThanOrEqual(frame.width, 0, name)
                XCTAssertGreaterThanOrEqual(frame.height, 0, name)
                if rendered.surface.layout.core.kind(of: element) == .shader {
                    XCTAssertEqual(frame, CGRect(origin: .zero, size: size), name)
                }
            }
            await until { rendered.surface.shaders.values.allSatisfy { !$0.program.isCompiling } }
            XCTAssertNil(rendered.surface.failedShader, name)
            if ["media", "control-center"].contains(name), snapshotsEnabled {
                await until {
                    ShellLayerScene.engineQueue.sync { rendered.layers().contains { $0.contents is IOSurface } }
                }
                rendered.surface.view.setFrameSize(size)
                try capture(rendered.surface.view, name: name)
            }
        }
    }

    func testControlCenterAndMediaKeepTheirCommandsAndSliderSemantics() throws {
        let controls = try widget("control-center")
        controls.render(bar())
        var tree = controls.renderPopout()
        let commands = tree.map { controls.text.string($0.content.action) }
        for command in ["wifi settings", "bluetooth settings", "volume mute", "media toggle", "battery settings"] {
            XCTAssertTrue(commands.contains(command), command)
        }
        let volume = try XCTUnwrap(tree.first { $0.kind == .slider }?.content.action)
        XCTAssertEqual(controls.invoke(
            volume, view: OMNI_VIEW_POPOUT, event: ShellEvent(value: 0.37, phase: .changed, kind: .slider)
        ), ["volume set 37"])
        for (label, command) in [
            ("Audio", "volume output 42"), ("Media", "media next"), ("Calendar", "calendar month next")
        ] {
            tree = controls.renderPopout()
            let tab = try XCTUnwrap(tree.first { controls.text.string($0.content.help) == label })
            controls.invoke(tab.content.action, view: OMNI_VIEW_POPOUT)
            XCTAssertTrue(
                controls.renderPopout().contains { controls.text.string($0.content.action) == command },
                label
            )
        }
        let media = try widget("media")
        media.render(bar())
        tree = media.renderPopout()
        XCTAssertTrue(media.strings(OMNI_VIEW_POPOUT).contains("Spring Walk"))
        for command in ["media previous", "media toggle", "media next", "media open"] {
            XCTAssertTrue(tree.contains { media.text.string($0.content.action) == command }, command)
        }
        let seek = try XCTUnwrap(tree.first { $0.kind == .slider }?.content.action)
        var event = ShellEvent(value: 0.75, phase: .changed, kind: .slider)
        XCTAssertEqual(media.invoke(seek, view: OMNI_VIEW_POPOUT, event: event), [])
        event.phase = .ended
        XCTAssertEqual(media.invoke(seek, view: OMNI_VIEW_POPOUT, event: event), ["media seek 150.0"])
    }

    func testPetalsAnimateOnBarsAndPanelsAndHonorStaticControls() async throws {
        executionTimeAllowance = 60
        let resources = try resources()
        let shader = try XCTUnwrap(config.barShader)
        let program = resources.shaders.program(
            source: shader.source, directories: config.directories.map { $0.appendingPathComponent("shaders") }
        )
        await until { !program.isCompiling }
        let pipeline = try XCTUnwrap(program.pipeline, program.failure ?? "")
        for (size, values) in [
            (CGSize(width: 320, height: 40), shader.values),
            (CGSize(width: 40, height: 320), shader.values),
            (CGSize(width: 348, height: 480), SIMD4<Float>(0.36, 0.8, 13, 0))
        ] {
            let render = { (time: Double, values: SIMD4<Float>, fps: Int) in
                let input = ShellShaderInput(values: values, rate: fps, colors: resources.palette.shaderColors)
                return try ShellShaderTests.pixels(pipeline, input.uniforms(
                    size: size, scale: 1, elapsed: time, now: 0, transition: .settled
                ), width: Int(size.width), height: Int(size.height))
            }
            let first = try render(0, values, 30)
            XCTAssertNotEqual(first, try render(3, values, 30), "\(size)")
            XCTAssertTrue(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 255 })
            XCTAssertEqual(try render(0, values, 0), try render(3, values, 0))
            var frozen = values
            frozen.y = 0
            XCTAssertEqual(try render(0, frozen, 30), try render(3, frozen, 30))
            var disabled = values
            disabled.x = 0
            let background = try render(0, disabled, 30)
            XCTAssertEqual(background, try render(3, disabled, 30))
            XCTAssertNotEqual(background, first)
        }
        if snapshotsEnabled {
            try await captureBar(program: program, resources: resources)
        }
    }

    private func resources() throws -> ShellResources {
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.palette.refresh(theme: config.theme, appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        return resources
    }

    private func widget(_ name: String) throws -> ShellRenderedWidget {
        let sourceURL = try XCTUnwrap(config.widget(name))
        let source = try ShellWidgetSourceLoader.build(.init(
            name: name, shellDirectory: shell, sourceURL: sourceURL,
            directories: config.directories, profile: config.profile
        ))
        let resources = try resources()
        let rendered = try ShellRenderedWidget(
            name: name, source: source.main,
            directories: [sourceURL.deletingLastPathComponent()] + config.directories,
            modules: source.modules, chunk: source.chunk, resources: resources
        )
        rendered.surface.assetFolders = source.assetPackages
        resources.shaders.onChange = { [weak surface = rendered.surface] in surface?.refreshShaders() }
        if let settings = config.widgetSettings[name] {
            XCTAssertEqual(settings.withUnsafeBufferPointer {
                omni_instance_set_value(rendered.instance, "settings", $0.baseAddress, $0.count)
            }, OMNI_OK)
        }
        for (key, value) in [
            ("clock", "09:41"), ("date", "Sun 11 Oct"), ("app", "Terminal"),
            ("title", "Sakura"), ("bundle", "com.apple.Terminal")
        ] {
            rendered.set(key) { $0.string(value) }
        }
        rendered.set("menuApp") {
            ShellMenuApp(pid: 42, name: "Terminal", bundle: "com.apple.Terminal").write(into: &$0)
        }
        for (key, value) in [("seconds", 1_000_030.0), ("battery", 82), ("volume", 40), ("cpu", 23), ("memory", 41)] {
            rendered.set(key) { $0.number(value) }
        }
        rendered.set("charging") { $0.bool(false) }
        rendered.set("muted") { $0.bool(false) }
        rendered.set("privacy") { ShellPrivacy(microphone: true, camera: false).write(into: &$0) }
        rendered.set("wifi") {
            ShellWiFi(power: true, connected: true, ssid: "Home", location: "authorized").write(into: &$0)
        }
        rendered.set("bluetooth") { ShellBluetooth(power: true, access: "granted", devices: []).write(into: &$0) }
        rendered.set("outputs") {
            $0.array(1)
            ShellAudioOutput(id: 42, name: "Speakers", transport: "builtin", isDefault: true).write(into: &$0)
        }
        rendered.set("media") {
            var media = ShellMedia()
            media.title = "Spring Walk"
            media.artist = "Morning Sessions"
            media.bundle = "com.apple.Music"
            media.playing = true
            media.duration = 200
            media.elapsed = 20
            media.rate = 1
            media.sampledAt = 1_000_000
            media.write(into: &$0)
        }
        rendered.set("calendar") {
            ShellCalendar(access: "full", events: [], month: ShellCalendarMonth(
                title: "October 2026", year: 2026, month: 10, days: 31, offset: 4, today: 11,
                weekdays: ["S", "M", "T", "W", "T", "F", "S"], marked: []
            )).write(into: &$0)
        }
        rendered.set("weather") {
            ShellWeather(temp: 18, code: 0, day: true, unit: "°C", place: "Toronto").write(into: &$0)
        }
        return rendered
    }

    private func bar(vertical: Bool = false) -> ShellBarData {
        let window = ShellBarWindow(id: "terminal", title: "Sakura", focused: true, hidden: false)
        let item = ShellBarItem(
            id: window.id, bundle: "com.apple.Terminal", name: "Terminal", focused: true,
            count: 1, hidden: 0, windows: [window]
        )
        var bar = ShellBarData()
        bar.style.height = 40
        bar.style.vertical = vertical
        bar.style.position = vertical ? "left" : "top"
        bar.style.backgrounds = false
        bar.workspaces = [
            ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [item]),
            ShellBarWorkspace(id: "2", name: "2", focused: false, windows: [])
        ]
        bar.scratchpads = [
            ShellBarScratchpad(id: 1, name: "Console", focused: false, revealed: true, visible: true, windows: [item])
        ]
        return bar
    }

    private var snapshotsEnabled: Bool {
        ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil
    }

    private func captureBar(program: ShellShaderProgram, resources: ShellResources) async throws {
        let background = ShellBarShaderView()
        background.setFrameSize(CGSize(width: 1440, height: 40))
        background.update(program: program, input: ShellShaderInput(
            values: try XCTUnwrap(config.barShader).values, rate: 0, colors: resources.palette.shaderColors
        ), paused: false)
        defer { background.stop() }
        let scene = try XCTUnwrap(background.scene)
        scene.submit([.visibility(true)], animated: false)
        await until { ShellLayerScene.engineQueue.sync { scene.layers[0]?.contents is IOSurface } }
        var widgets: [ShellRenderedWidget] = []
        var overlays: [(NSView, CGPoint)] = []
        for (index, names) in [config.leading, config.center, config.trailing].enumerated() {
            let lane = try names.map { name in
                let rendered = try widget(name)
                rendered.render(bar())
                return rendered
            }
            let width = lane.reduce(CGFloat(0)) { $0 + $1.surface.size.width } + CGFloat(max(0, lane.count - 1)) * 8
            var x = index == 0 ? 12 : index == 1 ? (1440 - width) / 2 : 1428 - width
            for rendered in lane {
                let size = rendered.surface.size
                rendered.surface.view.setFrameSize(size)
                overlays.append((rendered.surface.view, CGPoint(x: x, y: (40 - size.height) / 2)))
                x += size.width + 8
            }
            widgets += lane
        }
        try withExtendedLifetime(widgets) {
            try capture(background, name: "bar", overlays: overlays)
        }
    }

    private func capture(_ view: NSView, name: String, overlays: [(NSView, CGPoint)] = []) throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"])
        ShellLayerScene.engineQueue.sync {}
        let size = view.bounds.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 2, y: -2)
        try XCTUnwrap(view.layer).render(in: context)
        for (overlay, origin) in overlays {
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            try XCTUnwrap(overlay.layer).render(in: context)
            context.restoreGState()
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("sakura-\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
