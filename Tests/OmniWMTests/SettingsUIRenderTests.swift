// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest

@MainActor
final class SettingsUIRenderTests: XCTestCase {
    private struct WindowClass {
        let size: CGSize
        let dark: Bool
        var suffix: String {
            "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
        }
    }

    private let windowClasses = [
        WindowClass(size: CGSize(width: 760, height: 560), dark: true),
        WindowClass(size: CGSize(width: 1040, height: 760), dark: false)
    ]

    @MainActor
    private final class Fixture {
        let directory: URL
        let settings: SettingsStore
        let controller: WMController
        let corners: GlobalWindowCornerPreferences

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SettingsUIRenderTests-\(UUID().uuidString)")
            settings = SettingsStore(
                persistence: SettingsFilePersistence(
                    directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
                ),
                runtimeState: RuntimeStateStore(
                    directory: directory.appendingPathComponent("state"),
                    deferSaves: false
                ),
                autosaveEnabled: false
            )
            settings.workspaceBar.enabled = false
            settings.island.enabled = false
            settings.animationsEnabled = false
            settings.hotkeyBindings = []
            settings.hasSeenIssueWalkthrough = true
            settings.appRules = [
                AppRule(bundleId: "com.example.Editor", layout: .tile, assignToWorkspace: "1"),
                AppRule(bundleId: "com.example.Chat", layout: .float),
                AppRule(bundleId: "com.example.Browser", titleSubstring: "Documentation", layout: .tile)
            ]
            controller = WMController(
                settings: settings,
                clipboardHistoryDirectory: directory.appendingPathComponent("clipboard"),
                diagnosticsDirectory: directory.appendingPathComponent("diagnostics"),
                ownedWindowRegistry: OwnedWindowRegistry()
            )
            controller.workspaceBarManager.setup(controller: controller, settings: settings)
            corners = GlobalWindowCornerPreferences(operations: .init(
                copyMultiple: { [:] }, setMultiple: { _, _ in }, synchronize: { true }, isForced: { _ in false }
            ), isSupported: false)
        }

        func prepare() async throws {
            let configuration = controller.workspaceBarManager.shellConfiguration
            XCTAssertEqual(
                configuration.shellDirectory.standardizedFileURL.path,
                directory.appendingPathComponent("config/shell", isDirectory: true).standardizedFileURL.path
            )
            try await configuration.refresh()
            _ = try await configuration.selectProfile("lake")
            XCTAssertNil(controller.workspaceBarManager.shellHost)
        }

        func close() async {
            await controller.workspaceBarManager.shellConfiguration.flush()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testEverySettingsDestinationRendersNativeContentAtBothWindowClasses() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        do {
            let originalConfiguration = fixture.controller.workspaceBarManager.shellConfiguration.config
            for windowClass in windowClasses {
                for section in SettingsSection.allCases {
                    let navigation = SettingsNavigationModel()
                    navigation.section = section
                    let root = SettingsView(
                        settings: fixture.settings, controller: fixture.controller,
                        windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
                    )
                    try await render(
                        root, fixture: fixture, windowClass: windowClass,
                        section: section,
                        name: "settings-\(section.rawValue)-\(windowClass.suffix)",
                        requiredText: [String(localized: "Search settings"), section.subtitle, contentLabel(section)]
                            + paneLabels(section)
                    )
                    XCTAssertNil(fixture.controller.workspaceBarManager.shellHost, section.rawValue)
                    XCTAssertEqual(
                        fixture.controller.workspaceBarManager.shellConfiguration.config,
                        originalConfiguration, section.rawValue
                    )
                }
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPopulatedAppRulesAndItsEditorRenderAtNarrowAndWideSizes() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        do {
            for windowClass in windowClasses {
                let editorState = AppRulesEditorState()
                try await render(
                    AppRulesView(settings: fixture.settings, controller: fixture.controller, editorState: editorState),
                    fixture: fixture, windowClass: windowClass,
                    name: "app-rules-populated-\(windowClass.suffix)",
                    requiredText: [String(localized: "Add Rule"), "com.example.Chat"]
                )
                let editorClass = WindowClass(size: CGSize(
                    width: windowClass.dark ? 510 : 790, height: windowClass.size.height - 100
                ), dark: windowClass.dark)
                let rule = try XCTUnwrap(fixture.settings.appRules.first)
                try await render(
                    AppRuleDetailView(
                        rule: .constant(rule), workspaceNames: ["1", "2"], controller: fixture.controller,
                        editorState: editorState, onCreateRuleFromSnapshot: { _ in }, onDelete: {}
                    ),
                    fixture: fixture, windowClass: editorClass,
                    name: "app-rule-editor-\(editorClass.suffix)",
                    requiredText: [String(localized: "Save"), String(localized: "Revert"), "com.example.Editor"]
                )
                XCTAssertEqual(fixture.settings.appRules.first, rule)
                XCTAssertFalse(editorState.isDirty)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testSettingsSearchRendersItsActualResultsWithoutChangingConfiguration() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        do {
            let configuration = fixture.controller.workspaceBarManager.shellConfiguration
            let original = configuration.config
            for windowClass in windowClasses {
                let navigation = SettingsNavigationModel()
                navigation.searchText = "island"
                let root = SettingsView(
                    settings: fixture.settings, controller: fixture.controller,
                    windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
                )
                try await render(
                    root, fixture: fixture, windowClass: windowClass,
                    name: "settings-search-island-\(windowClass.suffix)",
                    requiredText: [String(localized: "Island Widgets"), String(localized: "Island Appearance")]
                )
                XCTAssertEqual(configuration.config, original)
                XCTAssertEqual(navigation.section, .general)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func render<Content: View>(
        _ content: Content, fixture: Fixture, windowClass: WindowClass, section: SettingsSection? = nil,
        name: String, requiredText: [String]
    ) async throws {
        let appearance = try XCTUnwrap(NSAppearance(named: windowClass.dark ? .darkAqua : .aqua))
        let originalAppearance = NSApp.appearance
        let originalActivationPolicy = NSApp.activationPolicy()
        XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
        NSApp.appearance = appearance
        defer { NSApp.appearance = originalAppearance
            _ = NSApp.setActivationPolicy(originalActivationPolicy)
        }
        let hostingController = NSHostingController(rootView: content
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, windowClass.dark ? .dark : .light)
            .transaction { $0.animation = nil })
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = String(localized: "OmniWM Settings")
        window.animationBehavior = .none
        window.hasShadow = false
        window.setContentSize(windowClass.size)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let hosting = hostingController.view
        defer { window.contentViewController = nil
            window.close()
        }
        window.center()
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await fixture.controller.workspaceBarManager.shellConfiguration.flush()
        await display(window, appearance: appearance)
        await fixture.controller.workspaceBarManager.shellConfiguration.flush()
        try await preparePreviews(
            fixture: fixture, section: section, dark: windowClass.dark, scale: window.backingScaleFactor
        )
        if section == .styles {
            let configuration = fixture.controller.workspaceBarManager.shellConfiguration
            let revision = configuration.revision
            NotificationCenter.default.post(name: .shellWidgetsDidChange, object: nil)
            await display(window, appearance: appearance)
            await configuration.flush()
            XCTAssertEqual(configuration.revision, revision, "Widget runtime status must preserve preview identity")
        }
        let currentSize = window.contentRect(forFrameRect: window.frame).size
        let layoutSize = window.contentLayoutRect.size
        window.setContentSize(CGSize(
            width: currentSize.width + windowClass.size.width - layoutSize.width,
            height: currentSize.height + windowClass.size.height - layoutSize.height
        ))
        window.center()
        hosting.layoutSubtreeIfNeeded()
        await display(window, appearance: appearance)
        let viewport = hosting.convert(window.contentLayoutRect, from: nil)
        XCTAssertEqual(viewport.size, windowClass.size, name)
        let bitmap = try await capture(window)
        XCTAssertEqual(bitmap.pixelsWide, Int(windowClass.size.width * window.backingScaleFactor), name)
        XCTAssertEqual(bitmap.pixelsHigh, Int(windowClass.size.height * window.backingScaleFactor), name)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.customWords = ["OmniWM", "Niri", "Dwindle", "Luau", "OmniShell"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertFalse(texts.isEmpty, "\(name): no native content was produced")
        let renderedText = normalizedText(texts.joined(separator: " "))
        for text in requiredText {
            XCTAssertTrue(
                renderedText.contains(normalizedText(text)),
                "\(name): missing \(text); rendered \(texts)"
            )
        }
        var colors: Set<Int> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 32)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 32)) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let red = Int((color.redComponent * 255).rounded())
                    let green = Int((color.greenComponent * 255).rounded())
                    let blue = Int((color.blueComponent * 255).rounded())
                    colors.insert(red << 16 | green << 8 | blue)
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 4, "\(name): the rendered image is empty or uniform")
        if let path = ProcessInfo.processInfo.environment["OMNIWM_SETTINGS_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        withExtendedLifetime(window) {}
    }

    private func preparePreviews(
        fixture: Fixture, section: SettingsSection?, dark: Bool, scale: CGFloat
    ) async throws {
        guard let section, [.styles, .bar, .island].contains(section) else { return }
        let configuration = fixture.controller.workspaceBarManager.shellConfiguration
        let profiles = section == .styles ? configuration.profiles : [configuration.config.profile]
        for profile in profiles {
            let config = try await configuration.previewConfig(profile: profile)
            if section != .island {
                _ = try await ShellSettingsPreview.cachedImage(for: .init(
                    config: config, surface: .bar,
                    style: ShellSettingsPreview.style(settings: fixture.settings.workspaceBar, config: config),
                    scale: scale, dark: dark,
                    fullWidth: config.barOverride?.settings.fullWidth
                        ?? (section == .styles ? fixture.settings.workspaceBar.fullWidth : false),
                    revision: configuration.revision
                ))
            }
            if config.profile == configuration.config.profile, config.island != nil, section != .bar {
                _ = try await ShellSettingsPreview.cachedImage(for: .init(
                    config: config, surface: .island(expanded: false), style: ShellBarStyle(),
                    scale: scale, dark: dark, fullWidth: config.barOverride?.settings.fullWidth ?? false,
                    revision: configuration.revision
                ))
            }
        }
    }

    private func requireNativeRendering() throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SETTINGS_UI_RENDER_TESTS"] == "1" else {
            throw XCTSkip("Native settings rendering requires OMNIWM_RUN_SETTINGS_UI_RENDER_TESTS=1")
        }
        _ = try XCTUnwrap(CGPreflightScreenCaptureAccess() ? true : nil, "Screen Recording permission is required")
    }

    private func normalizedText(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func display(_ window: NSWindow, appearance: NSAppearance) async {
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

    private func capture(_ window: NSWindow) async throws -> NSBitmapImageRep {
        let content = try await SCShareableContent.currentProcess
        let captureWindow = try XCTUnwrap(content.windows.first { Int($0.windowID) == window.windowNumber })
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let layout = window.contentLayoutRect
        let crop = CGRect(
            x: layout.minX * scale, y: (window.frame.height - layout.maxY) * scale,
            width: layout.width * scale, height: layout.height * scale
        )
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image.cropping(to: crop)))
    }

    private func paneLabels(_ section: SettingsSection) -> [String] {
        switch section {
        case .bar: [String(localized: "Layout"), String(localized: "Behavior"), String(localized: "Apps")]
        case .island: [String(localized: "Interaction"), String(localized: "Placement")]
        default: []
        }
    }

    private func contentLabel(_ section: SettingsSection) -> String {
        switch section {
        case .general: String(localized: "App Language")
        case .appearance: String(localized: "App Appearance")
        case .styles: String(localized: "Default")
        case .bar: String(localized: "Enable Workspace Bar")
        case .island: String(localized: "Enable Dynamic Island")
        case .widgets: String(localized: "Widget Library")
        case .menuBar: String(localized: "Show Workspace")
        case .workspaces: String(localized: "Layout Algorithm")
        case .layouts: String(localized: "Spacing")
        case .monitors: String(localized: "Arrangement")
        case .appRules: String(localized: "Add Rule")
        case .overview: String(localized: "Enable Overview")
        case .hotkeys: String(localized: "System Hyper Trigger")
        case .mouseTrackpad: String(localized: "Trackpad")
        case .quakeTerminal: String(localized: "Enable Quake Terminal")
        case .diagnostics: String(localized: "Health")
        case .reportIssue: String(localized: "Title")
        case .advanced: String(localized: "Reveal Settings File")
        }
    }
}
