// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private let unit = 1.35

struct PieceRun {
    let text: String
    let size: Double
    let weight: String
}

private struct PieceTimer {
    let request: VitreusRequest
    let cancelled: Bool
}

private func rounded(_ value: Double) -> Double {
    (value + 0.5).rounded(.down)
}

private func holdCrossing(rising: Bool) -> Double {
    let stiffness = 6.64 / 0.28
    var low = 0.0
    var high = 1.0
    for _ in 0 ..< 80 {
        let middle = (low + high) / 2
        let x = stiffness * middle
        let rest = exp(-x) * (1 + x)
        let progress = rising ? 1 - rest : rest
        if rising == (progress < 0.3) { low = middle } else { high = middle }
    }
    return (low + high) / 2
}

@MainActor
extension ShellVitreusBarTests {
    static let pieceOrder: ShellComponentValue = .strings(["title", "tray", "search", "omniwm", "controls", "clock"])
    static let titleOrder: ShellComponentValue = .strings(["title", "search", "omniwm", "controls"])

    func pieceWidget(
        _ shell: URL, pieces: ShellComponentValue = pieceOrder, animations: Bool = false, scale: CGFloat = 2,
        seed: (ShellRenderedWidget) -> Void = { _ in }
    ) throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), scale: scale,
            resources: VitreusFixture.resources(shell, animations: animations)
        )
        widget.surface.animates = animations
        VitreusFixture.settings(widget, ["pieces": pieces])
        seed(widget)
        VitreusFixture.show(widget)
        return widget
    }

    func pieceMeasure(_ shell: URL, _ runs: [PieceRun]) throws -> [CGSize] {
        let source = try VitreusFixture.source(shell)
        let calls = runs.map { "{ [==[\($0.text)]==], \($0.size), \"\($0.weight)\" }" }.joined(separator: ", ")
        let widget = try ShellRenderedWidget(
            name: "probe", source: """
            function render(ctx)
                local rows = {}
                for _, run in { \(calls) } do
                    local w, h = ctx.format.measure(run[1], { font = "Space Grotesk", size = run[2], weight = run[3] })
                    rows[#rows + 1] = w .. " " .. h
                end
                return ui.text{ text = table.concat(rows, ";") }
            end
            """, modules: source.modules, chunk: "@vitreus/widgets/probe/init.luau",
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders), memoryLimit: ShellWidgetPackage.memoryLimit,
            moduleLimit: source.moduleLimit
        )
        widget.render(ShellBarData())
        return try XCTUnwrap(widget.strings().first).split(separator: ";").map {
            let numbers = Self.numbers(String($0))
            return CGSize(width: numbers[0], height: numbers[1])
        }
    }

    func pieceHover(
        _ widget: ShellRenderedWidget, _ key: String, _ phase: ShellEvent.Phase, bar: ShellBarData? = nil
    ) throws {
        let action = try widget.surface.layout.core.content(of: VitreusFixture.element(widget, key: key)).hoverAction
        XCTAssertNotEqual(action, 0, key)
        var event = ShellEvent()
        event.phase = phase
        widget.invoke(action, event: event)
        VitreusFixture.show(widget, bar: bar)
    }

    fileprivate func pieceTimers(_ widget: ShellRenderedWidget) -> [PieceTimer] {
        var request = omni_service_request()
        var timers: [PieceTimer] = []
        while omni_vm_next_service(widget.vm, &request) {
            let entry = VitreusRequest(
                kind: request.kind, owner: request.owner, name: "", id: request.id, revision: request.revision,
                seconds: request.seconds, bytes: []
            )
            if request.kind == OMNI_SERVICE_TIMER {
                timers.append(PieceTimer(request: entry, cancelled: request.cancelled))
            } else if request.kind == OMNI_SERVICE_STORE {
                VitreusFixture.complete(widget, entry)
            }
        }
        return timers
    }

    func pieceStrokes(_ widget: ShellRenderedWidget, _ key: String) throws -> [String] {
        let layout = widget.surface.layout
        let icon = try VitreusFixture.element(widget, key: key)
        return layout.core.elements { _ in true }
            .filter { layout.core.parent(of: $0) == icon && layout.core.kind(of: $0) == .path }
            .map { widget.text.string(layout.core.content(of: $0).text) }
    }

    func piecePaint(_ widget: ShellRenderedWidget, _ key: String) throws -> Paint {
        try widget.surface.layout.core.paint(of: VitreusFixture.element(widget, key: key))
    }

    func pieceAssertHalo(_ widget: ShellRenderedWidget, _ keys: [String]) throws {
        for key in keys {
            let paint = try piecePaint(widget, key)
            XCTAssertEqual(paint.shadow.role & 0xFF, UInt16(ShellRole.shadow.rawValue + 1), key)
            XCTAssertEqual(Double(paint.shadow.role >> 8) / 255, 1, accuracy: 0.003, key)
            XCTAssertEqual(Double(paint.shadowRadius), 2.4 * unit, accuracy: 1e-4, key)
            XCTAssertEqual([paint.shadowOffsetX, paint.shadowOffsetY], [0, 0], key)
        }
    }

    func pieceRecipe(_ widget: ShellRenderedWidget, _ key: String) throws -> ShellGlassRecipe {
        let handle = try VitreusFixture.element(widget, key: key)
        return try XCTUnwrap(ShellGlassRecipe(widget.text.string(widget.surface.layout.core.content(of: handle).text)))
    }

    func testClockTextsSitAgainstTheirMeasuredWidthsWithTheVitreusShadow() throws {
        let shell = try shell()
        let widget = try pieceWidget(shell) { widget in
            widget.set("clock") { $0.string("9:41\u{202F}AM") }
            widget.set("date") { $0.string("Tue 28 Oct") }
        }
        let sizes = try pieceMeasure(shell, [
            PieceRun(text: "9", size: 40, weight: "bold"), PieceRun(text: ":41", size: 26, weight: "bold"),
            PieceRun(text: "TUE", size: 11, weight: "bold"), PieceRun(text: "am", size: 14, weight: "semibold")
        ])
        let column = max(sizes[2].width, sizes[3].width)
        let width = sizes[0].width + sizes[1].width + column
        let pill = try VitreusFixture.frame(widget, key: "shell")
        XCTAssertEqual(pill.width, 450 * unit, accuracy: 0.001)
        let right = pill.maxX - 16 * unit
        let zone = try VitreusFixture.frame(widget, key: "bar-clock")
        Self.assertRect(
            zone,
            CGRect(x: right + 4 * unit - width - 8 * unit, y: pill.minY, width: width + 8 * unit, height: pill.height)
        )
        func label(_ key: String) throws -> CGRect {
            try VitreusFixture.frame(widget, key: "clock-" + key)
        }
        XCTAssertEqual(try label("hour").maxX, rounded(right - column - sizes[1].width), accuracy: 0.001)
        XCTAssertEqual(try label("hour").width, sizes[0].width, accuracy: 0.001)
        XCTAssertEqual(try label("tail").maxX, rounded(right - column - 3), accuracy: 0.001)
        XCTAssertEqual(try label("lead").maxX, try label("tail").minX + 3, accuracy: 0.001)
        for (key, y) in [("day", rounded(pill.midY - 8)), ("meridiem", rounded(pill.midY + 7))] {
            XCTAssertEqual(try label(key).midX, rounded(right - column / 2), accuracy: 0.001, key)
            XCTAssertEqual(try label(key).midY, y, accuracy: 0.001, key)
        }
        XCTAssertEqual(try label("hour").midY, rounded(pill.midY), accuracy: 0.001)
        let texts = Dictionary(uniqueKeysWithValues: VitreusFixture.labels(widget).map { ($0.text, $0.frame) })
        XCTAssertEqual(Set(texts.keys).intersection(["9", ":4", "1", "TUE", "am"]).count, 5)
        for key in ["hour", "lead", "tail", "day", "meridiem"] {
            let paint = try piecePaint(widget, "clock-" + key)
            XCTAssertEqual(paint.shadow.role & 0xFF, UInt16(ShellRole.shadow.rawValue + 1), key)
            XCTAssertEqual(Double(paint.shadow.role >> 8) / 255, 0.4, accuracy: 0.003, key)
            XCTAssertEqual(paint.shadowRadius, 3, key)
            XCTAssertEqual([paint.shadowOffsetX, paint.shadowOffsetY], [0, 1], key)
        }
        let underline = try pieceStrokes(widget, "clock-group")
        XCTAssertEqual(underline.count, 2)
        XCTAssertEqual(try piecePaint(widget, "clock-group").scale, 1)
        try pieceHover(widget, "bar-clock", .began)
        XCTAssertEqual(try piecePaint(widget, "clock-group").scale, 1.08, accuracy: 1e-6)
        XCTAssertNotEqual(try pieceStrokes(widget, "clock-group"), underline)
    }

    func testTitleButtonTakesItsMeasuredWidthAndMakesRoomForTheTransportWhileAPlayerExists() throws {
        let shell = try shell()
        let named = { (widget: ShellRenderedWidget) in
            widget.set("app") { $0.string("Safari") }
            widget.set("title") { $0.string("Apple") }
        }
        let sizes = try pieceMeasure(shell, [
            PieceRun(text: "Safari", size: 17, weight: "semibold"), PieceRun(
                text: "Apple",
                size: 13.5,
                weight: "medium"
            )
        ])
        let display = VitreusFixture.bar().monitorId
        for playing in [nil, false, true] {
            let widget = try pieceWidget(shell, pieces: Self.titleOrder) { widget in
                named(widget)
                if let playing {
                    widget.set("media") { ShellMedia(title: "Song", app: "Music", playing: playing).write(into: &$0) }
                }
            }
            let pill = try VitreusFixture.frame(widget, key: "shell")
            let x = pill.minX + 16 * unit
            let media = playing != nil
            let stretch = pill.width - (32 + 12 + 15 + 13 + 36) * unit - (media ? 12 * unit : 0)
            let control = media ? 54 * unit : 0
            let hw = min(max(max(sizes[0].width + control, sizes[1].width) + 12 * unit, 48 * unit), stretch)
            let button = try VitreusFixture.frame(widget, key: "title-button")
            Self.assertRect(button, CGRect(x: x - 6 * unit, y: pill.minY, width: hw, height: pill.height))
            XCTAssertEqual(
                widget.surface.command(at: CGPoint(x: button.minX + 8, y: button.midY)),
                "shell trigger vitreus drawer-player \(display)"
            )
            let app = try VitreusFixture.frame(widget, key: "title-app")
            XCTAssertEqual(app.minX, rounded(x), accuracy: 0.001)
            XCTAssertEqual(app.midY, rounded(pill.midY - 6.5 * unit), accuracy: 0.001)
            let content = try widget.surface.layout.core.content(of: VitreusFixture.element(widget, key: "title-app"))
            XCTAssertEqual(Double(content.maxWidth), hw - 12 * unit - control, accuracy: 0.01)
            XCTAssertEqual(
                try VitreusFixture.frame(widget, key: "title-text").midY,
                rounded(pill.midY + 8.75 * unit),
                accuracy: 0.001
            )
            XCTAssertEqual(Self.has(widget, "title-play"), media)
            guard let playing else { continue }
            try pieceAssertTransport(
                widget,
                center: CGPoint(x: x - 6 * unit + hw - 27.5 * unit, y: pill.midY - 6.5 * unit)
            )
            XCTAssertEqual(try pieceStrokes(widget, "title-play-icon").count, playing ? 4 : 3)
        }
    }

    func pieceAssertTransport(_ widget: ShellRenderedWidget, center: CGPoint) throws {
        for (key, side, command) in [
            ("previous", -1.0, "media previous"), ("play", 0, "media toggle"), ("next", 1, "media next")
        ] {
            let zone = try VitreusFixture.frame(widget, key: "title-" + key)
            XCTAssertEqual(zone.midX, center.x + side * 17 * unit, accuracy: 0.001, key)
            XCTAssertEqual(zone.midY, center.y, accuracy: 0.001, key)
            XCTAssertEqual(zone.width, 17 * unit, accuracy: 0.001, key)
            XCTAssertEqual(zone.height, 18 * unit, accuracy: 0.001, key)
            XCTAssertEqual(widget.surface.command(at: CGPoint(x: zone.midX, y: zone.midY)), command, key)
        }
        try pieceAssertHalo(widget, ["title-previous-icon", "title-play-icon", "title-next-icon"])
    }
}

@MainActor
extension ShellVitreusBarTests {
    func testEmptyTitleShowsDotsAndTheHoverTabRevealsOnTheKitHoldUnlessMotionIsReduced() throws {
        let shell = try shell()
        for animations in [false, true] {
            let widget = try pieceWidget(shell, pieces: Self.titleOrder, animations: animations)
            let pill = try VitreusFixture.frame(widget, key: "shell")
            let stretch = pill.width - (32 + 12 + 15 + 13 + 36) * unit
            let middle = pill.minX + 16 * unit + stretch / 2
            for index in 1 ... 3 {
                let dot = try VitreusFixture.frame(widget, key: "title-dot-\(index)")
                XCTAssertEqual(dot.midX, middle + Double(index - 2) * 8 * unit, accuracy: 0.001)
                XCTAssertEqual(dot.midY, pill.midY, accuracy: 0.001)
                XCTAssertEqual(dot.width, 3.8 * unit, accuracy: 0.001)
            }
            XCTAssertFalse(Self.has(widget, "title-tab"))
            try pieceHover(widget, "title-button", .began)
            let layout = widget.surface.layout
            let tab = try VitreusFixture.element(widget, key: "title-tab")
            XCTAssertEqual(layout.core.kind(of: tab), .shape)
            XCTAssertEqual(layout.core.parent(of: tab), try VitreusFixture.element(widget, key: "bar"))
            Self.assertRect(try VitreusFixture.frame(widget, key: "title-tab"), CGRect(
                x: middle - 26 * unit, y: pill.midY, width: 52 * unit, height: pill.height / 2 + 3.5 * unit
            ))
            try pieceAssertTabReveal(widget, tab, animations: animations)
            VitreusFixture.trigger(widget.instance, "drawer-player", VitreusFixture.bar().monitorId)
            VitreusFixture.show(widget)
            XCTAssertFalse(Self.has(widget, "title-tab"))
            VitreusFixture.trigger(widget.instance, "drawer-close", nil)
            VitreusFixture.show(widget)
            XCTAssertTrue(Self.has(widget, "title-tab"))
            try pieceHover(widget, "title-button", .ended)
            XCTAssertFalse(Self.has(widget, "title-tab"))
        }
    }

    func pieceAssertTabReveal(_ widget: ShellRenderedWidget, _ tab: ElementHandle, animations: Bool) throws {
        let paint = widget.surface.layout.core.paint(of: tab)
        let reveal = try XCTUnwrap(widget.surface.reveal(paint.reveal))
        XCTAssertEqual(reveal.response, 0.513, accuracy: 1e-6)
        XCTAssertEqual(reveal.bounce, 0.06, accuracy: 1e-6)
        XCTAssertEqual(reveal.delay, holdCrossing(rising: true), accuracy: 1e-4)
        XCTAssertEqual(reveal.hold, holdCrossing(rising: false), accuracy: 1e-4)
        XCTAssertEqual(reveal.delay, 0.046, accuracy: 0.001)
        XCTAssertEqual(reveal.hold, 0.103, accuracy: 0.001)
        let morph = try XCTUnwrap(widget.surface.morph(paint.morph))
        XCTAssertEqual(morph.anchor, CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(morph.stops.map(\.height), [0, 1])
        let entry = try XCTUnwrap(ShellLayerScene.engineQueue
            .sync { widget.surface.scene.shapeTracks.entries[tab.slot] })
        let longest = entry.animations.map(\.animation.duration).max() ?? 0
        if animations {
            let plan = try XCTUnwrap(entry.plan)
            XCTAssertEqual(plan.begin - plan.commit, reveal.delay, accuracy: 1e-6)
            XCTAssertGreaterThan(longest, reveal.delay)
        } else {
            XCTAssertNil(entry.plan)
            XCTAssertEqual(longest, 0)
        }
    }

    func testTrayRowFollowsHiddenBarItemsAndPrivacyLights() throws {
        let shell = try shell()
        let items = [
            ShellHiddenBarItem(id: "wifi", name: "Wi-Fi", image: nil, width: 22, height: 22),
            ShellHiddenBarItem(id: "sound", name: "Sound", image: "hidden-bar/sound/1", width: 44, height: 22)
        ]
        let widget = try pieceWidget(shell) { widget in
            widget
                .set("hiddenBar") { ShellHiddenBarData(enabled: true, available: true, items: items).write(into: &$0) }
            widget.set("privacy") { ShellPrivacy(microphone: true, camera: true).write(into: &$0) }
        }
        let pill = try VitreusFixture.frame(widget, key: "shell")
        XCTAssertEqual(pill.width, (450 + 90 + 12) * unit, accuracy: 0.001)
        let center = pill.maxX - 16 * unit - (12 + 15 + 13 + 36) * unit - 45 * unit
        let left = rounded(center - 45 * unit)
        let top = rounded(pill.midY - 9 * unit)
        for (index, key) in ["microphone", "camera"].enumerated() {
            let light = try VitreusFixture.frame(widget, key: "tray-" + key)
            Self.assertRect(light, CGRect(x: left + Double(index) * 32, y: top, width: 24, height: 24), key)
        }
        let disc = try piecePaint(widget, "tray-microphone-disc")
        XCTAssertEqual([disc.fill.red, disc.fill.green, disc.fill.blue].map { ($0 * 255).rounded() }, [245, 158, 11])
        XCTAssertEqual(Double(disc.fill.alpha), 0x45 / 255, accuracy: 0.002)
        for (index, item) in items.enumerated() {
            let zone = try VitreusFixture.frame(widget, key: "tray-" + item.id)
            Self.assertRect(zone, CGRect(
                x: left + Double(index + 2) * 32 - 3 * unit, y: top - 6 * unit, width: 24 * unit, height: 30 * unit
            ), item.id)
            XCTAssertEqual(
                widget.surface.command(at: CGPoint(x: zone.midX, y: zone.midY)), "hidden-bar activate \(item.id)"
            )
        }
        Self.assertRect(try VitreusFixture.frame(widget, key: "tray-sound-image"), CGRect(
            x: left + 3 * 32, y: top + 6, width: 24, height: 12
        ))
        try pieceAssertHalo(widget, ["tray-microphone", "tray-camera", "tray-wifi-icon", "tray-sound-icon"])
        XCTAssertEqual(try piecePaint(widget, "tray-wifi-plate").opacity, 0)
        try pieceHover(widget, "tray-wifi", .began)
        XCTAssertEqual(try piecePaint(widget, "tray-wifi-plate").opacity, 1)
        XCTAssertEqual(try piecePaint(widget, "tray-wifi-icon").scale, 1.14, accuracy: 1e-6)
        widget.set("privacy") { ShellPrivacy(microphone: false, camera: false).write(into: &$0) }
        VitreusFixture.show(widget)
        XCTAssertFalse(Self.has(widget, "tray-microphone"))
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "shell").width, (450 + 42 + 12) * unit, accuracy: 0.001)
    }

    func testButtonsAndClockRunExistingCommandsAndTheControlsIconTurnsMintWhileItsDrawerIsOpen() throws {
        let shell = try shell()
        let widget = try pieceWidget(shell) { $0.set("clock") { $0.string("9:41 AM") } }
        let display = VitreusFixture.bar().monitorId
        let pill = try VitreusFixture.frame(widget, key: "shell")
        let expected = [
            ("bar-search", "open-command-palette", 24.0), ("bar-omniwm", "shell menu", 24),
            ("bar-controls", "shell trigger vitreus drawer-controls \(display)", 26)
        ]
        for (key, command, width) in expected {
            let zone = try VitreusFixture.frame(widget, key: key)
            XCTAssertEqual(zone.width, width * unit, accuracy: 0.001, key)
            XCTAssertEqual(zone.height, pill.height, accuracy: 0.001, key)
            XCTAssertEqual(widget.surface.command(at: CGPoint(x: zone.midX, y: zone.midY)), command, key)
        }
        let clock = try VitreusFixture.element(widget, key: "bar-clock")
        let content = widget.surface.layout.core.content(of: clock)
        XCTAssertEqual(widget.text.string(content.action), "shell trigger vitreus drawer-calendar \(display)")
        XCTAssertEqual(widget.text.string(content.secondaryAction), "shell trigger vitreus drawer-close \(display)")
        let rest = try piecePaint(widget, "bar-controls-icon")
        XCTAssertEqual(rest.opacity, 0.65, accuracy: 1e-6)
        XCTAssertEqual(rest.scale, 1)
        try pieceAssertHalo(widget, ["bar-search-icon", "bar-omniwm-icon", "bar-controls-icon"])
        VitreusFixture.trigger(widget.instance, "drawer-controls", display)
        VitreusFixture.show(widget)
        XCTAssertEqual(try piecePaint(widget, "bar-controls-icon").opacity, 1, accuracy: 1e-6)
        let layout = widget.surface.layout
        let icon = try VitreusFixture.element(widget, key: "bar-controls-icon")
        let strokes = layout.core.elements { _ in true }.filter { layout.core.parent(of: $0) == icon }
        XCTAssertFalse(strokes.isEmpty)
        for stroke in strokes {
            let paint = layout.core.paint(of: stroke)
            let color = paint.stroke.role != 0 ? paint.stroke : paint.fill
            XCTAssertEqual(color.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
        }
        XCTAssertEqual(try piecePaint(widget, "bar-omniwm-icon").opacity, 1, accuracy: 1e-6)
    }

    func testTheOmniWMLogoOpensTheStatusMenuShowsTheSecureInputLockAndAlwaysStays() throws {
        let widget = try pieceWidget(shell(), pieces: .strings(["title", "search", "controls"]))
        XCTAssertTrue(Self.has(widget, "bar-omniwm"))
        var bar = VitreusFixture.bar()
        for locked in [false, true] {
            bar.style.secureInput = locked
            VitreusFixture.show(widget, bar: bar)
            let layout = widget.surface.layout
            let icon = try VitreusFixture.element(widget, key: "bar-omniwm-icon")
            let children = layout.core.elements { _ in true }.filter { layout.core.parent(of: $0) == icon }
            XCTAssertEqual(children.map { layout.core.kind(of: $0) }, [.symbol])
            let symbol = layout.core.content(of: try XCTUnwrap(children.first))
            XCTAssertEqual(widget.text.string(symbol.text), locked ? "omniwm.lock" : "omniwm")
            XCTAssertEqual(symbol.color, Color(packed: 0xB665_45FF))
            let zone = layout.core.content(of: try VitreusFixture.element(widget, key: "bar-omniwm"))
            XCTAssertEqual(widget.text.string(zone.secondaryAction), ShellRequest.statusMenuCommand)
            let help = locked ? "Secure Input is on: Option shortcuts are paused" : "Window manager controls"
            XCTAssertEqual(widget.text.string(zone.help), ShellLocalizer.string(help, []))
        }
        XCTAssertTrue(pieceTimers(widget).isEmpty)
        try pieceHover(widget, "bar-omniwm", .began)
        XCTAssertTrue(pieceTimers(widget).isEmpty)
        XCTAssertEqual(try piecePaint(widget, "bar-omniwm-icon").scale, 1.14, accuracy: 1e-6)
    }

    func testPencilRedrawsAtFiveHertzOnlyWhileHoveredAndCancelsOnLeave() throws {
        let shell = try shell()
        let widget = try pieceWidget(shell) { widget in
            widget.set("clock") { $0.string("9:41 AM") }
            widget.set("media") { ShellMedia(title: "Song", app: "Music", playing: true).write(into: &$0) }
        }
        XCTAssertTrue(pieceTimers(widget).isEmpty)
        for (zone, icon) in [
            ("bar-search", "bar-search-icon"),
            ("bar-clock", "clock-group"),
            ("title-next", "title-next-icon")
        ] {
            let rest = try pieceStrokes(widget, icon)
            try pieceHover(widget, zone, .began)
            let first = pieceTimers(widget)
            XCTAssertEqual(first.count, 1, zone)
            XCTAssertEqual(try XCTUnwrap(first.first).request.seconds, 0.2, accuracy: 1e-9, zone)
            XCTAssertFalse(try XCTUnwrap(first.first).cancelled, zone)
            let hovered = try pieceStrokes(widget, icon)
            XCTAssertNotEqual(hovered, rest, zone)
            VitreusFixture.complete(widget, try XCTUnwrap(first.first).request)
            VitreusFixture.show(widget)
            let next = pieceTimers(widget)
            XCTAssertEqual(next.map(\.cancelled), [false], zone)
            XCTAssertNotEqual(try pieceStrokes(widget, icon), hovered, zone)
            try pieceHover(widget, zone, .ended)
            XCTAssertEqual(pieceTimers(widget).map(\.cancelled), [true], zone)
            XCTAssertEqual(try pieceStrokes(widget, icon), rest, zone)
            VitreusFixture.show(widget)
            XCTAssertTrue(pieceTimers(widget).isEmpty, zone)
        }
        try pieceHover(widget, "title-button", .began)
        XCTAssertTrue(pieceTimers(widget).isEmpty)
    }

    func testHoverAndPencilTimerEndWhenTheHoveredPieceLeavesTheBar() throws {
        let shell = try shell()
        let item = ShellHiddenBarItem(id: "wifi", name: "Wi-Fi", image: nil, width: 22, height: 22)
        let tray = ShellHiddenBarData(enabled: true, available: true, items: [item])
        let empty = ShellHiddenBarData(enabled: true, available: true)
        let pieces: ShellComponentValue = .strings(["title", "tray", "omniwm", "controls"])
        let widget = try pieceWidget(shell) { widget in
            widget.set("media") { ShellMedia(title: "Song", app: "Music", playing: true).write(into: &$0) }
            widget.set("hiddenBar") { tray.write(into: &$0) }
            widget.set("battery") { $0.number(50) }
        }
        let removals: [(String, (ShellRenderedWidget) -> Void)] = [
            ("bar-search", { VitreusFixture.settings($0, ["pieces": pieces]) }),
            ("title-next", { $0.set("media") { $0.null() } }),
            ("tray-wifi", { $0.set("hiddenBar") { empty.write(into: &$0) } })
        ]
        for (key, remove) in removals {
            let zone = try VitreusFixture.frame(widget, key: key)
            let point = CGPoint(x: zone.midX, y: zone.midY)
            let began = widget.events.count
            widget.surface.pointer = point
            widget.surface.updateHoverIntent(at: point)
            VitreusFixture.deliver(widget, from: began)
            XCTAssertEqual(try piecePaint(widget, "battery-track").opacity, 0.1, accuracy: 1e-6, key)
            let armed = pieceTimers(widget)
            XCTAssertEqual(armed.map(\.cancelled), key == "tray-wifi" ? [] : [false], key)
            remove(widget)
            let removed = widget.events.count
            VitreusFixture.show(widget)
            XCTAssertFalse(Self.has(widget, key), key)
            let ended = try XCTUnwrap(widget.events.dropFirst(removed).first, key)
            XCTAssertEqual(ended.event.phase, .ended, key)
            widget.invoke(ended.action, event: ended.event)
            VitreusFixture.show(widget)
            XCTAssertEqual(pieceTimers(widget).map(\.cancelled), armed.map { _ in true }, key)
            XCTAssertEqual(try piecePaint(widget, "battery-track").opacity, 0, key)
        }
    }
}
