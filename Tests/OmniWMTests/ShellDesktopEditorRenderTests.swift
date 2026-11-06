// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension ShellDesktopEditorTests {
        func testDesktopEditorSubstatesRenderAtMinimumAndDefaultWindowClasses() async throws {
            _ = try XCTUnwrap(CGPreflightScreenCaptureAccess() ? true : nil, "Screen Recording permission is required")
            _ = NSApplication.shared
            let originalPolicy = NSApp.activationPolicy()
            let originalAppearance = NSApp.appearance
            XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
            defer {
                NSApp.appearance = originalAppearance
                _ = NSApp.setActivationPolicy(originalPolicy)
            }
            let classes: [(CGSize, Bool)] = [
                (CGSize(width: 539, height: 480), true), (CGSize(width: 819, height: 680), false)
            ]
            for (size, dark) in classes {
                for state in ["active", "previewing", "widget", "display", "dirty-draft"] {
                    let fixture = try await fixture(style: state == "active" ? "default" : "lake")
                    let editor = fixture.editor
                    var labels = [String(localized: "All Displays (sample preview)")]
                    switch state {
                    case "active": labels.append(String(localized: "Active"))
                    case "previewing": labels.append(String(localized: "Use Style"))
                    case "widget":
                        _ = await editor.selectWidget("scratchpads")
                        labels.append(String(localized: "Bar Settings"))
                    case "display":
                        let monitor = try XCTUnwrap(editor.monitors.first, "A native display is required")
                        editor.selectMonitor(monitor.id)
                        labels = [monitor.name, String(localized: "Use Style")]
                    default:
                        _ = await editor.selectWidget("control-center")
                        await editor.beginWeatherDraft()
                        guard case var .weather(weather)? = editor.draft(.weather)?.value else {
                            return XCTFail("Missing shared Weather draft")
                        }
                        weather.city = "London"
                        editor.updateDraft(.weather, .weather(weather))
                        labels.append(String(localized: "Bar Settings"))
                    }
                    let suffix = "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
                    try await renderDesktopEditor(
                        fixture, size: size, dark: dark, name: "editor-\(state)-\(suffix)", labels: labels
                    )
                    XCTAssertEqual(editor.configuration.config.profile, "default")
                    XCTAssertNil(editor.controller.workspaceBarManager.shellHost)
                    if state == "dirty-draft" { XCTAssertTrue(editor.draft(.weather)?.dirty == true) }
                }
            }
        }

        func testCompoundEditorDraftsRenderDirectlyAtBothWindowClasses() async throws {
            _ = try XCTUnwrap(CGPreflightScreenCaptureAccess() ? true : nil, "Screen Recording permission is required")
            _ = NSApplication.shared
            let originalPolicy = NSApp.activationPolicy()
            let originalAppearance = NSApp.appearance
            XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
            defer {
                NSApp.appearance = originalAppearance
                _ = NSApp.setActivationPolicy(originalPolicy)
            }
            for (size, dark) in [(CGSize(width: 539, height: 480), true), (CGSize(width: 819, height: 680), false)] {
                for kind in CompoundDraftKind.allCases {
                    let fixture = try await fixture()
                    let original = try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml"))
                    let key = try await prepareCompoundDraft(kind, editor: fixture.editor)
                    XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
                    try await renderCompoundDraft(kind, editor: fixture.editor, size: size, dark: dark)
                    XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
                    XCTAssertEqual(try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml")), original)
                    XCTAssertEqual(fixture.configuration.config.profile, "default")
                    XCTAssertNil(fixture.editor.controller.workspaceBarManager.shellHost)
                }
            }
        }

        private enum CompoundDraftKind: String, CaseIterable {
            case weather
            case clocks
            case text
        }

        private func prepareCompoundDraft(
            _ kind: CompoundDraftKind, editor: ShellDesktopEditor
        ) async throws -> ShellEditorDraft.Key {
            switch kind {
            case .weather:
                await editor.beginWeatherDraft()
                let draft = try XCTUnwrap(editor.draft(.weather))
                guard case var .weather(weather) = draft.value else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                weather.city = "London"
                editor.updateDraft(.weather, .weather(weather))
                return .weather
            case .clocks:
                editor.beginClocksDraft()
                let key = ShellEditorDraft.Key(widget: "world-clock", option: "zones")
                let clocks = [ShellWorldClockEntry(label: "Toronto", zone: "America/Toronto")]
                editor.updateDraft(key, .clocks(clocks))
                return key
            case .text:
                let key = ShellEditorDraft.Key(widget: "launcher", option: "symbol")
                XCTAssertEqual(editor.schema(for: "launcher")?.options["symbol"]?.kind, .string)
                editor.beginTextDraft(widget: "launcher", key: "symbol")
                editor.updateDraft(key, .text("star"))
                return key
            }
        }

        @ViewBuilder
        private func compoundDraft(_ kind: CompoundDraftKind, editor: ShellDesktopEditor) -> some View {
            switch kind {
            case .weather: ShellDesktopWeatherDraft(editor: editor)
            case .clocks: ShellDesktopClocksDraft(editor: editor)
            case .text:
                Section("Launcher") {
                    ShellDesktopTextDraft(
                        editor: editor, widget: "launcher", option: "symbol", title: "Symbol", multiline: false,
                        maximum: editor.schema(for: "launcher")?.options["symbol"]?.maxLength ?? 0
                    )
                }
            }
        }

        private func renderCompoundDraft(
            _ kind: CompoundDraftKind, editor: ShellDesktopEditor, size: CGSize, dark: Bool
        ) async throws {
            let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            NSApp.appearance = appearance
            let host = NSHostingController(rootView: Form { compoundDraft(kind, editor: editor) }
                .formStyle(.grouped)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.animation = nil })
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .resizable]
            window.title = "Compound editor"
            window.animationBehavior = .none
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.setContentSize(size)
            defer { window.contentViewController = nil
                window.close()
            }
            window.center()
            window.orderBack(nil)
            await desktopDisplay(window, appearance: appearance)
            await editor.configuration.flush()
            let current = window.contentRect(forFrameRect: window.frame).size
            let layout = window.contentLayoutRect.size
            window.setContentSize(CGSize(
                width: current.width + size.width - layout.width,
                height: current.height + size.height - layout.height
            ))
            await desktopDisplay(window, appearance: appearance)
            XCTAssertEqual(host.view.convert(window.contentLayoutRect, from: nil).size, size)
            let bitmap = try await captureDesktopEditor(window)
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width * window.backingScaleFactor))
            XCTAssertEqual(bitmap.pixelsHigh, Int(size.height * window.backingScaleFactor))
            var labels = [String(localized: "Save"), String(localized: "Cancel")]
            if kind == .weather { labels += [String(localized: "Shared by all styles"), "London"] }
            if kind == .clocks { labels.append("Toronto") }
            if kind == .text { labels.append("star") }
            let suffix = "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
            try assertDesktopBitmap(bitmap, name: "editor-draft-\(kind.rawValue)-\(suffix)", labels: labels)
            withExtendedLifetime(window) {}
        }

        private func renderDesktopEditor(
            _ fixture: Fixture, size: CGSize, dark: Bool, name: String, labels: [String]
        ) async throws {
            let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            NSApp.appearance = appearance
            let navigation = SettingsNavigationModel()
            navigation.proceed(to: SettingsRoute(section: .styles))
            let host = NSHostingController(rootView: ShellDesktopEditorPage(editor: fixture.editor)
                .environment(navigation)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.animation = nil })
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .resizable]
            window.title = "Styles & Widgets"
            window.animationBehavior = .none
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.setContentSize(size)
            defer {
                fixture.editor.detach()
                window.contentViewController = nil
                window.close()
            }
            window.center()
            window.orderBack(nil)
            await desktopDisplay(window, appearance: appearance)
            try await prepareDesktopPreviews(fixture.editor, dark: dark, scale: window.backingScaleFactor)
            await fixture.configuration.flush()
            await desktopDisplay(window, appearance: appearance)
            let current = window.contentRect(forFrameRect: window.frame).size
            let layout = window.contentLayoutRect.size
            window.setContentSize(CGSize(
                width: current.width + size.width - layout.width,
                height: current.height + size.height - layout.height
            ))
            await desktopDisplay(window, appearance: appearance)
            XCTAssertEqual(host.view.convert(window.contentLayoutRect, from: nil).size, size, name)
            let bitmap = try await captureDesktopEditor(window)
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width * window.backingScaleFactor), name)
            XCTAssertEqual(bitmap.pixelsHigh, Int(size.height * window.backingScaleFactor), name)
            try assertDesktopBitmap(bitmap, name: name, labels: labels)
            withExtendedLifetime(window) {}
        }

        private func assertDesktopBitmap(_ bitmap: NSBitmapImageRep, name: String, labels: [String]) throws {
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            recognition.usesLanguageCorrection = true
            recognition.customWords = ["OmniWM", "Nocturne", "Celestial"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            XCTAssertFalse(text.isEmpty, name)
            let normalized = desktopNormalized(text)
            for label in labels {
                XCTAssertTrue(
                    normalized.contains(desktopNormalized(label)),
                    "\(name): missing \(label); rendered \(text)"
                )
            }
            if let path = ProcessInfo.processInfo.environment["OMNIWM_SETTINGS_SNAPSHOTS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
        }

        private func prepareDesktopPreviews(_ editor: ShellDesktopEditor, dark: Bool, scale: CGFloat) async throws {
            for profile in editor.configuration.profiles {
                let config = try await editor.configuration.previewConfig(profile: profile)
                _ = try await ShellSettingsPreview.cachedImage(for: .init(
                    config: config, surface: .bar,
                    style: ShellSettingsPreview.style(settings: editor.settings.workspaceBar, config: config),
                    scale: scale, dark: dark, fullWidth: config.barOverride?.settings.fullWidth ?? false,
                    sourceGeneration: editor.configuration.sourceGeneration
                ))
            }
            let snapshot = try XCTUnwrap(editor.snapshot)
            let style = try XCTUnwrap(editor.previewStyle)
            _ = try await ShellSettingsPreview.cachedImage(for: .init(
                config: snapshot.config, surface: .bar, style: style, scale: scale, dark: dark,
                fullWidth: snapshot.config.barOverride?.settings.fullWidth ?? false,
                sourceGeneration: editor.configuration.sourceGeneration, display: editor.previewDisplay
            ))
        }

        private func desktopDisplay(_ window: NSWindow, appearance: NSAppearance) async {
            await withCheckedContinuation { continuation in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                CATransaction.setCompletionBlock { continuation.resume() }
                appearance.performAsCurrentDrawingAppearance {
                    NSApp.updateWindows()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.display()
                }
                CATransaction.commit()
                CATransaction.flush()
            }
        }

        private func captureDesktopEditor(_ window: NSWindow) async throws -> NSBitmapImageRep {
            let content = try await SCShareableContent.currentProcess
            let source = try XCTUnwrap(content.windows.first { Int($0.windowID) == window.windowNumber })
            let options = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            options.width = Int(window.frame.width * scale)
            options.height = Int(window.frame.height * scale)
            options.showsCursor = false
            options.ignoreShadowsSingleWindow = true
            options.shouldBeOpaque = true
            let filter = SCContentFilter(desktopIndependentWindow: source)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: options)
            let rect = window.contentLayoutRect
            let crop = CGRect(
                x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                width: rect.width * scale, height: rect.height * scale
            )
            return NSBitmapImageRep(cgImage: try XCTUnwrap(image.cropping(to: crop)))
        }

        private func desktopNormalized(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
#endif
