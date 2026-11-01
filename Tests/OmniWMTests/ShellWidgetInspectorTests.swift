// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class ShellWidgetInspectorTests: XCTestCase {
    private struct Option {
        let widget: String
        let key: String
        let minimum: Double
        let maximum: Double
        let schemaDefault: Double
        let styleDefault: Double
    }

    private let options = [
        Option(
            widget: "scratchpads",
            key: "shownWindows",
            minimum: 0,
            maximum: 6,
            schemaDefault: 3,
            styleDefault: 2
        ),
        Option(
            widget: "calendar",
            key: "agendaEvents",
            minimum: 1,
            maximum: 12,
            schemaDefault: 6,
            styleDefault: 6
        ),
        Option(
            widget: "weather",
            key: "forecastHours",
            minimum: 4,
            maximum: 12,
            schemaDefault: 12,
            styleDefault: 12
        )
    ]

    func testNocturneInspectorUpdatesAtBoundsAndRestoresDefaultAppearance() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        _ = NSApp.setActivationPolicy(.accessory)
        defer { _ = NSApp.setActivationPolicy(activationPolicy) }
        let (directory, configuration) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = await editor(configuration: configuration, directory: directory)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for option in options {
                try await configuration.reset(table: "widgets." + option.widget)
                await editor.reload()
                _ = await editor.selectWidget(option.widget)
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 600, height: 620),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                defer { window.contentView = nil
                    window.close()
                }
                window.appearance = NSAppearance(named: appearance)
                let host = inspector(editor: editor, widget: option.widget, appearance: appearance)
                window.contentView = host
                window.orderBack(nil)
                let cases: [(String, Double?)] = [
                    ("default", nil), ("minimum", option.minimum), ("maximum", option.maximum), ("reset", nil)
                ]
                var pixels: [String: Data] = [:]
                for (state, number) in cases {
                    if let number {
                        try await configuration.setWidgetValue(.number(number), widget: option.widget, key: option.key)
                    } else {
                        try await configuration.reset(table: "widgets." + option.widget)
                    }
                    await editor.reload()
                    await display(window)
                    pixels[state] = try snapshot(
                        host,
                        name: "nocturne-inspector-\(option.widget)-\(appearance == .darkAqua ? "dark" : "light")-\(state)"
                    )
                }
                try await assertInspectorSnapshots(
                    pixels, option: option, appearance: appearance, window: window, editor: editor
                )
            }
        }
    }

    func testNocturneOptionsSurviveReloadAndStyleSwitchAndResetToStyleDefaults() async throws {
        let (directory, configuration) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for option in options {
            try await configuration.setWidgetValue(.number(option.minimum), widget: option.widget, key: option.key)
        }
        let reloaded = ShellConfigurationCoordinator(shellDirectory: directory)
        try await reloaded.ensureLoaded()
        XCTAssertEqual(reloaded.config.profile, "nocturne")
        for option in options {
            XCTAssertEqual(
                ShellWidgetSettingsModel.values(widget: option.widget, config: reloaded.config)[option.key],
                .number(option.minimum)
            )
        }
        try await reloaded.selectProfile("default")
        for option in options {
            XCTAssertNil(ShellWidgetSettingsModel.values(widget: option.widget, config: reloaded.config)[option.key])
        }
        XCTAssertEqual(reloaded.widgetSchemas["scratchpads"]?.options["shownWindows"]?.defaultValue, .number(3))
        try await reloaded.selectProfile("nocturne")
        for option in options {
            XCTAssertEqual(
                ShellWidgetSettingsModel.values(widget: option.widget, config: reloaded.config)[option.key],
                .number(option.minimum)
            )
            try await reloaded.reset(table: "widgets." + option.widget)
        }
        let reset = ShellConfigurationCoordinator(shellDirectory: directory)
        try await reset.ensureLoaded()
        for option in options {
            XCTAssertFalse(ShellProfiles.hasTopLevel(
                [ShellProfiles.key("widgets", of: "nocturne") + [option.widget, option.key]], in: directory
            ), option.widget)
            let schemaDefault = try XCTUnwrap(reset.widgetSchemas[option.widget]?.options[option.key]?.defaultValue)
            XCTAssertEqual(schemaDefault, .number(option.schemaDefault), option.widget)
            XCTAssertEqual(
                ShellWidgetSettingsModel.values(widget: option.widget, config: reset.config)[option.key]
                    ?? schemaDefault,
                .number(option.styleDefault),
                option.widget
            )
        }
    }

    private func assertInspectorSnapshots(
        _ pixels: [String: Data],
        option: Option,
        appearance: NSAppearance.Name,
        window: NSWindow,
        editor: ShellDesktopEditor
    ) async throws {
        XCTAssertNotEqual(pixels["default"], pixels["minimum"], option.widget)
        XCTAssertNotEqual(pixels["minimum"], pixels["maximum"], option.widget)
        XCTAssertEqual(pixels["default"], pixels["reset"], option.widget)
        if option.styleDefault == option.maximum {
            XCTAssertEqual(pixels["default"], pixels["maximum"], option.widget)
        }
        guard appearance == .aqua else { return }
        let view = try XCTUnwrap(window.contentView)
        let probes = [
            option.minimum,
            option.maximum,
            option.styleDefault - 1,
            option.styleDefault,
            option.styleDefault + 1
        ]
        .filter { (option.minimum ... option.maximum).contains($0) }
        for value in Set(probes).sorted() {
            try await editor.configuration.setWidgetValue(.number(value), widget: option.widget, key: option.key)
            await editor.reload()
            await display(window)
            let reference = try snapshot(
                view,
                name: "nocturne-inspector-\(option.widget)-light-value-\(value)"
            )
            let context = "\(option.widget) \(appearance.rawValue) \(value)"
            for state in ["default", "reset"] {
                if value == option.styleDefault {
                    XCTAssertEqual(pixels[state], reference, context)
                } else {
                    XCTAssertNotEqual(pixels[state], reference, context)
                }
            }
        }
    }

    private func inspector(editor: ShellDesktopEditor, widget: String, appearance: NSAppearance.Name) -> NSView {
        NSHostingView(rootView: Form {
            ShellDesktopWidgetInspector(editor: editor, widget: widget)
        }
        .formStyle(.grouped)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        .transaction { $0.animation = nil })
    }

    private func editor(configuration: ShellConfigurationCoordinator, directory: URL) async -> ShellDesktopEditor {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        let editor = ShellDesktopEditor(configuration: configuration, settings: settings, controller: controller)
        await editor.reload()
        return editor
    }

    private func fixture() async throws -> (URL, ShellConfigurationCoordinator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try ShellStyleFixture.prepare(into: directory)
        _ = try ShellProfiles.select("nocturne", in: directory)
        let configuration = ShellConfigurationCoordinator(shellDirectory: directory)
        try await configuration.ensureLoaded()
        XCTAssertNil(configuration.metadataError)
        XCTAssertTrue(configuration.configProblems.isEmpty)
        return (directory, configuration)
    }

    private func snapshot(_ view: NSView, name: String) throws -> Data {
        let area = view.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(area.width * 2), pixelsHigh: Int(area.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = area.size
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        bytes.initialize(repeating: 0, count: count)
        view.cacheDisplay(in: area, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        return Data(bytes: bytes, count: count)
    }

    private func display(_ window: NSWindow) async {
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { continuation.resume() }
            NSApp.updateWindows()
            window.contentView?.layoutSubtreeIfNeeded()
            window.display()
            CATransaction.commit()
            CATransaction.flush()
        }
    }
}
