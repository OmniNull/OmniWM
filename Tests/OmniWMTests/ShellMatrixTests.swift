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
final class ShellMatrixTests: XCTestCase {
    private var shell: URL!
    private var config: ShellConfig!

    override func setUp() async throws {
        shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("matrix", in: shell))
        var problems: [String] = []
        config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shell)
    }

    func testProfileInstallsTheRainBarAndInheritsTheEffectsGallery() throws {
        XCTAssertEqual(config.profile, "matrix")
        XCTAssertEqual(config.themeName, "matrix")
        XCTAssertEqual(
            config.leading,
            ["apple-menu", "app-menu", "omniwm", "workspaces", "scratchpads", "active-window"]
        )
        XCTAssertEqual(config.center, ["clock"])
        XCTAssertEqual(config.trailing, ["privacy", "media", "wifi", "battery-details", "control-center"])
        XCTAssertEqual(config.barOverride?.settings.height, 40)
        XCTAssertEqual(config.barOverride?.settings.fullWidth, true)
        XCTAssertEqual(config.barOverride?.settings.reserveLayoutSpace, true)
        XCTAssertEqual(config.barShader, ShellBarShader(
            source: "matrix-rain.metal", fps: 30, values: SIMD4(0.38, 1, 12, 1)
        ))
        XCTAssertEqual(
            config.widget("effects-lab"), shell.appendingPathComponent("default/widgets/effects-lab/init.luau")
        )
        let gallery = try widget("effects-lab")
        gallery.render(bar())
        XCTAssertTrue(gallery.tree().first?.content.opensPopout == true)
        XCTAssertFalse(gallery.renderPopout().isEmpty)
    }

    func testPresetWidgetsFitBothOrientationsAndResolveTheirAnimatedPopouts() async throws {
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
            let tree = rendered.renderPopout()
            let shader = try XCTUnwrap(tree.first { $0.kind == .shader }, name)
            XCTAssertEqual(rendered.text.string(shader.content.text), "matrix-rain.metal", name)
            XCTAssertEqual(shader.content.rate, 30, name)
            rendered.layoutPopout()
            XCTAssertGreaterThan(rendered.surface.size.width, 0, name)
            XCTAssertGreaterThan(rendered.surface.size.height, 0, name)
            await until { rendered.surface.shaders.values.allSatisfy { !$0.program.isCompiling } }
            XCTAssertNil(rendered.surface.failedShader, name)
            if ["media", "control-center"].contains(name) {
                try await capture(rendered, name: name)
            }
        }
    }

    func testCompactWorkspacesKeepMenuDropAndClickTargets() throws {
        for vertical in [false, true] {
            let rendered = try widget("workspaces")
            rendered.render(bar(vertical: vertical))
            XCTAssertEqual(Set(rendered.surface.targetFrames().map { rendered.text.string($0.target) }), [
                "workspace 1", "workspace 2"
            ])
            for id in ["1", "2"] {
                let button = try XCTUnwrap(rendered.surface.layout.core.elements {
                    $0.menu && $0.drop && rendered.text.string($0.target) == "workspace \(id)"
                }.first)
                let frame = CGRect(rendered.surface.layout.core.absoluteFrame(of: button))
                let point = CGPoint(x: frame.midX, y: frame.midY)
                rendered.surface.press(at: point)
                rendered.surface.release(at: point)
                XCTAssertEqual(rendered.clicks.last?.action, "switch-workspace \(id)")
            }
        }
    }

    func testWindowPickerKeepsItsHeaderAndLastWindowReachableWithinAShortPopout() throws {
        let rendered = try widget("workspaces")
        rendered.set("settings") {
            $0.map(1)
            $0.key("compact")
            $0.bool(false)
        }
        let windows = (0 ..< 20).map {
            ShellBarWindow(id: "window_\($0)", title: "Terminal \($0)", focused: $0 == 0, hidden: false)
        }
        let item = ShellBarItem(
            id: "terminals", bundle: "com.apple.Terminal", name: "Terminal", focused: true,
            count: windows.count, hidden: 0, windows: windows
        )
        var data = bar()
        data.workspaces = [ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [item])]
        rendered.render(data)
        let picker = try XCTUnwrap(rendered.tree()
            .first { rendered.text.string($0.content.target) == "window terminals" })
        rendered.invoke(picker.content.action)
        rendered.layoutPopout()
        let scroll = try XCTUnwrap(rendered.surface.layout.core.elements { $0.scrolls }.first)
        let naturalHeight = rendered.surface.layout.core.layoutFrame(of: scroll).height
        rendered.surface.setRootLimit(CGSize(width: rendered.surface.size.width, height: 180))
        let bounds = CGRect(origin: .zero, size: rendered.surface.size)
        let header = try XCTUnwrap(rendered.surface.layout.core.elements {
            rendered.text.string($0.text) == "Terminal"
        }.first)
        let headerFrame = CGRect(rendered.surface.layout.core.absoluteFrame(of: header))
        let bodyFrame = CGRect(rendered.surface.layout.core.absoluteFrame(of: scroll))
        XCTAssertEqual(bounds.height, 180)
        XCTAssertGreaterThanOrEqual(headerFrame.minY, bounds.minY)
        XCTAssertLessThanOrEqual(headerFrame.maxY, bounds.maxY)
        XCTAssertGreaterThanOrEqual(bodyFrame.minY, headerFrame.maxY)
        XCTAssertLessThanOrEqual(bodyFrame.maxY, bounds.maxY)
        XCTAssertLessThan(bodyFrame.height, CGFloat(naturalHeight))
        let visibleBody = bodyFrame.intersection(bounds)
        XCTAssertTrue(rendered.surface.scroll(
            at: CGPoint(x: visibleBody.midX, y: visibleBody.midY), event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: 10000)
        ))
        XCTAssertGreaterThan(rendered.surface.layout.core.scrollShift(scroll.slot).y, 0)
        let last = try XCTUnwrap(rendered.surface.layout.core.elements {
            rendered.text.string($0.action) == "window focus window_19"
        }.first)
        let lastFrame = CGRect(rendered.surface.layout.core.absoluteFrame(of: last))
        XCTAssertTrue(bounds.contains(lastFrame))
        let point = CGPoint(x: lastFrame.midX, y: lastFrame.midY)
        XCTAssertEqual(rendered.surface.command(at: point), "window focus window_19")
        rendered.surface.press(at: point)
        rendered.surface.release(at: point)
        XCTAssertEqual(rendered.clicks.last?.action, "window focus window_19")
    }

    func testControlCenterRetainsConnectionVolumeAndTabActions() throws {
        let rendered = try widget("control-center")
        rendered.render(bar())
        var tree = rendered.renderPopout()
        let commands = tree.map { rendered.text.string($0.content.action) }
        for command in ["wifi settings", "bluetooth settings", "volume mute", "media toggle", "battery settings"] {
            XCTAssertTrue(commands.contains(command), command)
        }
        let level = try XCTUnwrap(tree.first { $0.kind == .slider }?.content.action)
        let event = ShellEvent(value: 0.37, phase: .changed, kind: .slider)
        XCTAssertEqual(rendered.invoke(level, view: OMNI_VIEW_POPOUT, event: event), ["volume set 37"])
        for (label, command) in [
            ("Audio", "volume output 42"), ("Media", "media next"), ("Calendar", "calendar month next")
        ] {
            tree = rendered.renderPopout()
            let tab = try XCTUnwrap(tree.first { rendered.text.string($0.content.help) == label })
            rendered.invoke(tab.content.action, view: OMNI_VIEW_POPOUT)
            XCTAssertTrue(
                rendered.renderPopout().contains { rendered.text.string($0.content.action) == command },
                label
            )
        }
        for label in ["Weather", "System", "Control Center"] {
            tree = rendered.renderPopout()
            let tab = try XCTUnwrap(tree.first { rendered.text.string($0.content.help) == label })
            rendered.invoke(tab.content.action, view: OMNI_VIEW_POPOUT)
            XCTAssertFalse(rendered.renderPopout().isEmpty, label)
        }
    }

    func testMediaKeepsTrackDataTransportAndSeekCompletion() throws {
        let rendered = try widget("media")
        rendered.render(bar())
        XCTAssertTrue(rendered.strings().contains("Night Drive"))
        let tree = rendered.renderPopout()
        let strings = rendered.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(strings.contains("Night Drive"))
        XCTAssertTrue(strings.contains("Terminal Sessions"))
        for command in ["media previous", "media toggle", "media next", "media open"] {
            XCTAssertTrue(tree.contains { rendered.text.string($0.content.action) == command }, command)
        }
        let slider = try XCTUnwrap(tree.first { $0.kind == .slider }?.content.action)
        var event = ShellEvent(value: 0.75, phase: .changed, kind: .slider)
        XCTAssertEqual(rendered.invoke(slider, view: OMNI_VIEW_POPOUT, event: event), [])
        event.phase = .ended
        XCTAssertEqual(rendered.invoke(slider, view: OMNI_VIEW_POPOUT, event: event), ["media seek 150.0"])
    }

    func testRainRendersGreenAnimatedFramesAndHonorsStaticControls() async throws {
        executionTimeAllowance = 60
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: true))
        resources.palette.refresh(theme: config.theme, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))
        let shader = try XCTUnwrap(config.barShader)
        let program = resources.shaders.program(
            source: shader.source, directories: config.directories.map { $0.appendingPathComponent("shaders") }
        )
        await until { !program.isCompiling }
        let pipeline = try XCTUnwrap(program.pipeline, program.failure ?? "")
        let render = { (time: Double, values: SIMD4<Float>, fps: Int) in
            let uniforms = ShellShaderInput(values: values, rate: fps, colors: resources.palette.shaderColors).uniforms(
                size: CGSize(width: 320, height: 40), scale: 1, elapsed: time, now: 0, transition: .settled
            )
            return try ShellShaderTests.pixels(pipeline, uniforms, width: 320, height: 40)
        }
        let first = try render(0, shader.values, shader.fps)
        let later = try render(3, shader.values, shader.fps)
        XCTAssertNotEqual(first, later)
        XCTAssertTrue(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 255 })
        XCTAssertTrue(stride(from: 0, to: first.count, by: 4).allSatisfy {
            first[$0 + 1] >= first[$0] && first[$0 + 1] >= first[$0 + 2]
        })
        XCTAssertEqual(try render(0, shader.values, 0), try render(3, shader.values, 0))
        var frozen = shader.values
        frozen.y = 0
        XCTAssertEqual(try render(0, frozen, 30), try render(3, frozen, 30))
        var disabled = shader.values
        disabled.x = 0
        let background = try render(0, disabled, 30)
        XCTAssertEqual(background, try render(3, disabled, 30))
        XCTAssertNotEqual(background, first)
    }

    private func widget(_ name: String) throws -> ShellRenderedWidget {
        let sourceURL = try XCTUnwrap(config.widget(name))
        let source = try ShellWidgetSourceLoader.build(.init(
            name: name, shellDirectory: shell, sourceURL: sourceURL,
            directories: config.directories, profile: config.profile
        ))
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.palette.refresh(theme: config.theme, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)))
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
            ("clock", "23:41"),
            ("date", "Sun 11 Oct"),
            ("app", "Terminal"),
            ("title", "matrix"),
            ("bundle", "com.apple.Terminal")
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
            ShellWiFi(power: true, connected: true, ssid: "Operator", location: "authorized").write(into: &$0)
        }
        rendered.set("bluetooth") { ShellBluetooth(power: true, access: "granted", devices: []).write(into: &$0) }
        rendered.set("outputs") {
            $0.array(1)
            ShellAudioOutput(id: 42, name: "Speakers", transport: "builtin", isDefault: true).write(into: &$0)
        }
        rendered.set("media") {
            var media = ShellMedia()
            media.title = "Night Drive"
            media.artist = "Terminal Sessions"
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
            ShellWeather(temp: 18, code: 61, day: false, unit: "°C", place: "Toronto").write(into: &$0)
        }
        return rendered
    }

    private func bar(vertical: Bool = false) -> ShellBarData {
        let window = ShellBarWindow(id: "ow_terminal", title: "matrix", focused: true, hidden: false)
        let item = ShellBarItem(
            id: window.id, bundle: "com.apple.Terminal", name: "Terminal", focused: true,
            count: 1, hidden: 0, badge: "", floating: false, windows: [window]
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

    private func capture(_ rendered: ShellRenderedWidget, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        await until {
            ShellLayerScene.engineQueue.sync {
                rendered.layers().contains { $0.contents is IOSurface }
            }
        }
        ShellLayerScene.engineQueue.sync {}
        let size = rendered.surface.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 2, y: -2)
        try XCTUnwrap(rendered.surface.view.layer).render(in: context)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("matrix-\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

final class ShellBarShaderConfigTests: XCTestCase {
    func testConfigurationLayersAndCanDisableTheProfileShader() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        try Data("profile = \"matrix\"\n[profiles.matrix.barShader]\nfps = 12\nvalues = [0.2, 0]\n".utf8)
            .write(to: shell.appendingPathComponent("shell.toml"))
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(
            config.barShader,
            ShellBarShader(source: "matrix-rain.metal", fps: 12, values: SIMD4(0.2, 0, 0, 0))
        )
        try Data("profile = \"matrix\"\n[profiles.matrix.barShader]\nenabled = false\n".utf8)
            .write(to: shell.appendingPathComponent("shell.toml"))
        XCTAssertNil(ShellConfig.load(shellDirectory: shell, problems: &problems)?.barShader)
        XCTAssertEqual(problems, [])
    }

    func testInvalidShadersAreRejectedWithoutDiscardingTheRestOfTheConfig() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        let filename = "source = \"matrix-rain.metal\"\n"
        for declaration in [
            "", "source = \"../matrix-rain.metal\"", "source = \"matrix-rain\"", "source = \"/tmp/rain.metal\"",
            "source = \".hidden.metal\"", "source = \"\"", filename + "enabled = 1",
            filename + "fps = -1", filename + "fps = 61", filename + "fps = 0.5", filename + "fps = nan",
            filename + "values = [1, 2, 3, 4, 5]", filename + "values = [inf]",
            filename + "values = [1e100]", filename + "values = [\"green\"]"
        ] {
            try Data("[profiles.default]\nleading = [\"clock\"]\n[profiles.default.barShader]\n\(declaration)\n".utf8)
                .write(to: shell.appendingPathComponent("shell.toml"))
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems), declaration)
            XCTAssertEqual(config.leading, ["clock"], declaration)
            XCTAssertNil(config.barShader, declaration)
            XCTAssertTrue(problems.contains { $0.contains("[barShader]") }, declaration)
        }
    }
}
