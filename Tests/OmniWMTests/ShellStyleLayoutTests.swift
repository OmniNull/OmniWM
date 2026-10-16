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
final class ShellStyleLayoutTests: XCTestCase {
    private let applications = ["com.apple.Safari", "com.apple.Terminal", "com.apple.finder", "com.apple.Notes"]
    private let profiles = ["default", "wayline", "nocturne", "celestial", "lake", "system", "sakura"]

    func testManagedProfileEjectCreatesPersistentUserOverrides() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        let celestial = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(
            try ShellProfiles.eject("workspaces", config: celestial, shellDirectory: shell),
            shell.appendingPathComponent("widgets/workspaces", isDirectory: true)
        )
        XCTAssertNil(try ShellProfiles.eject("workspaces", config: celestial, shellDirectory: shell))
        XCTAssertNotNil(celestial.file("lib/shapes.luau"))
        let copied = try XCTUnwrap(ShellProfiles.eject("privacy", config: celestial, shellDirectory: shell))
        XCTAssertEqual(copied, shell.appendingPathComponent("widgets/privacy", isDirectory: true))
        XCTAssertTrue(try ShellProfiles.create("custom", in: shell))
        XCTAssertNotNil(ShellConfig.resolve(shellDirectory: shell).widget("custom"))
        XCTAssertTrue(try ShellProfiles.select("default", in: shell))
        let original = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(
            original.widget("workspaces"),
            shell.appendingPathComponent("widgets/workspaces/init.luau")
        )
        XCTAssertEqual(original.widget("privacy"), shell.appendingPathComponent("widgets/privacy/init.luau"))
        XCTAssertNil(original.widget("custom"))
        XCTAssertNil(original.file("lib/shapes.luau"))
    }

    func testStylesFitTheirThicknessAtBothBackingScalesAndOrientations() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        for profile in profiles {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            let base = config.barOverride?.settings.height ?? 24
            for height in [base, base * 1.5] {
                for vertical in [false, true] {
                    for scale in [CGFloat(1), 2] {
                        for dark in [false, true] {
                            try render(
                                config,
                                shell: shell,
                                height: height,
                                vertical: vertical,
                                scale: scale,
                                dark: dark
                            )
                        }
                    }
                }
            }
        }
    }

    func testSystemPresetKeepsCompactWorkspaceButtonsAndTargetsAcrossOrientations() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("system", in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        for vertical in [false, true] {
            for labels in [false, true] {
                let widget = try makeWidget("workspaces", config: config, shell: shell)
                var bar = fixture(config, height: 32, vertical: vertical)
                bar.style.labels = labels
                widget.render(bar)
                let size = widget.surface.size
                XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(vertical ? size.width : size.height, 32)
                let tree = widget.tree()
                XCTAssertFalse(tree.contains { $0.kind == .image && $0.content.iconSource == .window })
                XCTAssertEqual(Set(widget.surface.targetFrames().map { widget.text.string($0.target) }), [
                    "workspace 1", "workspace 2", "workspace 3"
                ])
                for workspace in bar.workspaces {
                    XCTAssertEqual(tree.contains {
                        $0.kind == .label && widget.text.string($0.content.text) == workspace.name
                    }, labels)
                    let button = try XCTUnwrap(widget.surface.layout.core.elements {
                        $0.menu && $0.drop && widget.text.string($0.target) == "workspace \(workspace.id)"
                    }.first)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
                    XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite)
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.clicks.last?.action, "switch-workspace \(workspace.id)")
                }
            }
        }
    }

    func testWorkspaceGroupsKeepTheirTargetsAndPickerAcrossProfilesAndOrientations() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        for profile in profiles {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            for vertical in [false, true] {
                for labels in [false, true] {
                    let widget = try makeWidget("workspaces", config: config, shell: shell)
                    if ["system", "sakura"].contains(profile) {
                        widget.set("settings") {
                            $0.map(1)
                            $0.key("compact")
                            $0.bool(false)
                        }
                    }
                    var bar = fixture(config, height: config.barOverride?.settings.height ?? 24, vertical: vertical)
                    bar.style.labels = labels
                    widget.render(bar)
                    let targets = widget.surface.targetFrames()
                    XCTAssertEqual(Set(targets.map { widget.text.string($0.target) }), [
                        "workspace 1", "workspace 2", "workspace 3", "window 0", "window 1", "window 2", "window 3"
                    ], "\(profile) vertical=\(vertical) labels=\(labels)")
                    let group = try XCTUnwrap(widget.tree()
                        .first { widget.text.string($0.content.target) == "window 1" })
                    XCTAssertTrue(group.content.menu && group.content.preview && group.content.drag && group.content
                        .opensPopout)
                    if profile == "wayline", labels {
                        let label = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.text) == "1"
                        }.first)
                        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: label))
                        let window = try XCTUnwrap(widget.surface.layout.core.elements {
                            $0.drag && widget.text.string($0.target) == "window 0"
                        }.first)
                        let icon = CGRect(widget.surface.layout.core.absoluteFrame(of: window))
                        XCTAssertLessThanOrEqual(vertical ? frame.maxY : frame.maxX, vertical ? icon.minY : icon.minX)
                    }
                    widget.invoke(group.content.action)
                    widget.layoutPopout()
                    if profile == "system" {
                        XCTAssertEqual(widget.surface.chrome, ShellPopoutChrome(glass: true, radius: 20))
                        if ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil {
                            try write(
                                [("workspaces", raster(widget.surface, scale: 2), widget.surface.size)],
                                name: "system-workspaces-picker-\(vertical ? "vertical" : "horizontal")-labels-\(labels)",
                                scale: 2, dark: false, solidBlack: false
                            )
                        }
                    }
                    for window in bar.workspaces[0].windows[1].windows {
                        let row = try XCTUnwrap(widget.surface.layout.core.elements {
                            widget.text.string($0.action) == "window focus \(window.id)"
                        }.first)
                        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: row))
                        let point = CGPoint(x: frame.midX, y: frame.midY)
                        widget.surface.press(at: point)
                        widget.surface.release(at: point)
                        XCTAssertEqual(widget.clicks.last?.action, "window focus \(window.id)")
                    }
                    let close = try XCTUnwrap(widget.surface.layout.core.elements { $0.action == OMNI_ACTION_POPOUT }
                        .first)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: close))
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    widget.surface.press(at: point)
                    widget.surface.release(at: point)
                    XCTAssertEqual(widget.actions.last, OMNI_ACTION_POPOUT)
                    if profile == "wayline", !labels {
                        bar.style.accents = false
                        bar.style.backgrounds = true
                        widget.render(bar)
                        let selected = try XCTUnwrap(widget.tree()
                            .first { $0.content.drop && widget.text.string($0.content.target) == "workspace 1" })
                        let inactive = try XCTUnwrap(widget.tree()
                            .first { $0.content.drop && widget.text.string($0.content.target) == "workspace 2" })
                        XCTAssertTrue(selected.paint.stroke.isVisible)
                        XCTAssertNotEqual(selected.paint.stroke, inactive.paint.stroke)
                    }
                    bar.workspaces.removeFirst()
                    widget.render(bar)
                    XCTAssertFalse(widget.renderPopout().contains { $0.content.action != 0 })
                }
            }
        }
    }

    func testUnderlineSpansTheWorkspaceWithOrWithoutLabelsAndRespectsAccents() throws {
        let widget = try ShellRenderedWidget("workspaces")
        widget.set("settings") {
            $0.map(1)
            $0.key("indicator")
            $0.string("underline")
        }
        for vertical in [false, true] {
            for labels in [false, true] {
                for accents in [false, true] {
                    var bar = fixture(ShellConfig(), height: 32, vertical: vertical)
                    bar.style.labels = labels
                    bar.style.accents = accents
                    widget.render(bar)
                    let paths = widget.surface.layout.core.elements { _ in true }.filter {
                        widget.surface.layout.core.kind(of: $0) == .path
                    }
                    XCTAssertEqual(paths.count, accents ? 1 : 0)
                    guard let path = paths.first else { continue }
                    let line = CGRect(widget.surface.layout.core.absoluteFrame(of: path))
                    let workspace = try XCTUnwrap(widget.surface.targetFrames().first {
                        widget.text.string($0.target) == "workspace 1"
                    }).frame
                    XCTAssertEqual(
                        vertical ? line.height : line.width,
                        vertical ? workspace.height : workspace.width,
                        accuracy: 0.01
                    )
                }
            }
        }
    }

    func testSolidBlackWorkspaceLabelsStayReadableInLightAndDarkAppearances() throws {
        let widget = try ShellRenderedWidget("workspaces")
        let black = ShellRGBA(CGColor(gray: 0, alpha: 1))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            widget.resources.palette.refresh(theme: .native, appearance: try XCTUnwrap(NSAppearance(named: appearance)))
            for accents in [false, true] {
                var bar = fixture(ShellConfig(), height: 32, vertical: false)
                bar.style.solidBlack = true
                bar.style.accents = accents
                widget.render(bar)
                for name in accents ? ["2", "3"] : ["1", "2", "3"] {
                    let label = try XCTUnwrap(widget.tree().first {
                        widget.text.string($0.content.text) == name
                            && widget.text.string($0.content.target) == "workspace \(name)"
                            && $0.kind == .label
                    })
                    let color = try ShellRGBA(XCTUnwrap(widget.resources.palette.color(label.content.color)))
                    XCTAssertGreaterThanOrEqual(color.contrast(black), 4.5, "\(appearance.rawValue) workspace \(name)")
                }
            }
        }
    }

    private func render(
        _ config: ShellConfig,
        shell: URL,
        height: Double,
        vertical: Bool,
        scale: CGFloat,
        dark: Bool
    ) throws {
        let resources = ShellResources(
            motion: MotionPolicy(animationsEnabled: false),
            windowIcon: { [applications] id in
                guard let index = Int(id), applications.indices.contains(index),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applications[index])
                else { return nil }
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        )
        var theme = config.theme
        for (role, color) in [
            (ShellRole.accent, config.barOverride?.accentColor),
            (.foreground, config.barOverride?.textColor)
        ] {
            guard let color else { continue }
            let value = NSColor(deviceRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
            theme.light[role.rawValue] = value
            theme.dark[role.rawValue] = value
        }
        resources.palette.refresh(
            theme: theme,
            appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        )
        let bar = fixture(config, height: height, vertical: vertical)
        var previews: [(String, CGImage, CGSize)] = []
        for name in ["workspaces", "scratchpads", "clock", "system-stats"] {
            let widget = try makeWidget(name, config: config, shell: shell, scale: scale, resources: resources)
            widget.set("clock") { $0.string("9:41 AM") }
            widget.set("date") { $0.string("Sat, Oct 10") }
            widget.set("cpu") { $0.number(42) }
            widget.set("memory") { $0.number(61) }
            widget.set("gpu") { $0.number(18) }
            widget.render(bar)
            let size = widget.surface.size
            XCTAssertGreaterThan(size.width, 0, "\(config.profile)/\(name)")
            XCTAssertGreaterThan(size.height, 0, "\(config.profile)/\(name)")
            XCTAssertLessThanOrEqual(
                vertical ? size.width : size.height,
                height,
                "\(config.profile)/\(name) \(height) vertical=\(vertical): \(size)"
            )
            if ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil {
                previews.append((name, try raster(widget.surface, scale: scale), size))
            }
        }
        if !previews.isEmpty {
            let name = "\(config.profile)-\(Int(height))-\(vertical ? "vertical" : "horizontal")-\(dark ? "dark" : "light")-\(Int(scale))x"
            try write(previews, name: name, scale: scale, dark: dark, solidBlack: bar.style.solidBlack)
        }
    }

    private func makeWidget(
        _ name: String,
        config: ShellConfig,
        shell: URL,
        scale: CGFloat = 2,
        resources: ShellResources? = nil
    ) throws -> ShellRenderedWidget {
        let source = try XCTUnwrap(config.widget(name))
        let chunk = String(source.path.dropFirst(shell.path.count + 1))
        let profile = chunk.split(separator: "/").first.map(String.init) ?? config.profile
        var modules: [ShellWidgetSource.Module] = []
        var seen: Set<String> = []
        for directory in config.directories {
            let library = directory.appendingPathComponent("lib")
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
                where entry.hasSuffix(".luau") && seen.insert(entry).inserted
            {
                modules.append(try ShellWidgetSource.Module(
                    path: "\(profile)/lib/\(entry)",
                    source: String(contentsOf: library.appendingPathComponent(entry), encoding: .utf8)
                ))
            }
        }
        let widget = try ShellRenderedWidget(
            name: name, source: String(contentsOf: source, encoding: .utf8), directories: config.directories,
            modules: modules, chunk: "@" + chunk, scale: scale, resources: resources
        )
        if let settings = config.widgetSettings[name] {
            XCTAssertEqual(settings.withUnsafeBufferPointer {
                omni_instance_set_value(widget.instance, "settings", $0.baseAddress, $0.count)
            }, OMNI_OK)
        }
        return widget
    }

    private func fixture(_ config: ShellConfig, height: Double, vertical: Bool) -> ShellBarData {
        var bar = ShellBarData(badges: "text")
        let settings = config.barOverride?.settings
        bar.style.labels = settings?.showLabels ?? bar.style.labels
        bar.style.backgrounds = settings?.showItemBackgrounds ?? bar.style.backgrounds
        bar.style.accents = settings?.showAccentHighlights ?? bar.style.accents
        bar.style.transparent = settings?.transparentBackground ?? bar.style.transparent
        bar.style.solidBlack = settings?.solidBlackBackground ?? bar.style.solidBlack
        bar.style.height = height
        bar.style.vertical = vertical
        bar.style.statsButton = true
        bar.style.position = vertical ? "left" : "top"
        let items = applications.enumerated().map { index, bundle in
            ShellBarItem(
                id: "\(index)", bundle: bundle, name: ["Safari", "Terminal", "Finder", "Notes"][index],
                focused: index == 0, count: index == 1 ? 2 : 1, hidden: index == 1 || index == 2 ? 1 : 0,
                badge: index == 0 ? "3" : "", floating: index == 3,
                windows: (0 ..< (index == 1 ? 2 : 1)).map { window in
                    ShellBarWindow(
                        id: "\(index)_\(window)", title: "Window \(index)-\(window)",
                        focused: index == 0, hidden: index == 2 || index == 1 && window == 0
                    )
                }
            )
        }
        bar.workspaces = [
            ShellBarWorkspace(id: "1", name: "1", focused: true, windows: Array(items.prefix(2))),
            ShellBarWorkspace(id: "2", name: "2", focused: false, windows: Array(items.suffix(2))),
            ShellBarWorkspace(id: "3", name: "3", focused: false, windows: [])
        ]
        bar.scratchpads = [
            ShellBarScratchpad(id: 1, name: "Chat", focused: false, revealed: true, visible: true, windows: [items[3]])
        ]
        return bar
    }

    private func raster(_ surface: ShellWidgetSurface, scale: CGFloat) throws -> CGImage {
        ShellLayerScene.engineQueue.sync {}
        let size = surface.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(surface.view.layer).render(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func write(
        _ previews: [(String, CGImage, CGSize)],
        name: String,
        scale: CGFloat,
        dark: Bool,
        solidBlack: Bool
    ) throws {
        let spacing: CGFloat = 24
        let width = previews.reduce(spacing) { $0 + $1.2.width + spacing }
        let height = (previews.map { $0.2.height }.max() ?? 0) + spacing * 2
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(width * scale)), height: Int(ceil(height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: solidBlack ? 0 : dark ? 0.09 : 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = spacing
        for (_, image, size) in previews {
            context.draw(
                image,
                in: CGRect(x: x, y: height - spacing - size.height, width: size.width, height: size.height)
            )
            x += size.width + spacing
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            directory.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
