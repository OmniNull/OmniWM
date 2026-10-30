// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest

@MainActor
final class SettingsUIRenderTests: XCTestCase {
    struct WindowClass {
        let size: CGSize
        let dark: Bool
        var suffix: String {
            "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
        }
    }

    let windowClasses = [
        WindowClass(size: CGSize(width: 760, height: 560), dark: true),
        WindowClass(size: CGSize(width: 1040, height: 760), dark: false)
    ]

    @MainActor
    final class Fixture {
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
            try ShellStyleFixture.installAll(into: configuration.shellDirectory)
            try await configuration.refresh()
            _ = try await configuration.selectProfile("lake")
            XCTAssertNil(controller.workspaceBarManager.shellHost)
        }

        func close() async {
            await controller.workspaceBarManager.shellConfiguration.flush()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testLauncherSettingsAndSharedEntryEditorRenderNatively() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        var entry = LauncherEntry()
        entry.name = "Build Project"
        entry.command = "swift build"
        fixture.settings.launcher.entries = [entry]
        do {
            for windowClass in windowClasses {
                let navigation = SettingsNavigationModel()
                navigation.section = .launcher
                try await render(
                    SettingsView(
                        settings: fixture.settings,
                        controller: fixture.controller,
                        windowCornerPreferences: fixture.corners,
                        updateCoordinator: nil,
                        navigation: navigation
                    ),
                    fixture: fixture, windowClass: windowClass, section: .launcher,
                    name: "launcher-\(windowClass.suffix)",
                    requiredText: [
                        "Saved Entries",
                        "Build Project",
                        "Execution Defaults",
                        "Discovery and Advanced Options"
                    ]
                )
            }
            for kind in LauncherEntry.Kind.allCases {
                var draft = entry
                draft.kind = kind
                draft.path = kind == .application ? "/Applications/Ghostty.app" : "/usr/bin/printf"
                if kind == .script || kind == .executable { draft.arguments = ["%s", "hello world"] }
                if kind == .script { draft.interpreter = "/bin/sh" }
                for dark in [true, false] {
                    try await render(
                        LauncherEntryEditor(
                            entry: draft, runOnly: kind == .executable, configuration: fixture.settings.launcher,
                            save: { _ in }, run: { _ in }
                        ),
                        fixture: fixture, windowClass: WindowClass(size: CGSize(width: 620, height: 600), dark: dark),
                        section: .launcher, name: "launcher-entry-\(kind.rawValue)-\(dark ? "dark" : "light")",
                        requiredText: [
                            kind == .executable ? "Run CLI" : "Launcher Entry",
                            "Build Project",
                            "Advanced Options",
                            "Cancel",
                            kind == .executable ? "Save Entry" : "Save"
                        ]
                    )
                }
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
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
                        requiredText: [String(localized: "Search settings"), section.subtitle, contentLabel(section)],
                        requiredObservations: paneLabels(section)
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

    func testNetworkPermissionsPageListsTheStyleWidgetsProgramsAndServices() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        do {
            for windowClass in windowClasses {
                let navigation = SettingsNavigationModel()
                navigation.section = .network
                let root = SettingsView(
                    settings: fixture.settings, controller: fixture.controller,
                    windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
                )
                try await render(
                    root, fixture: fixture, windowClass: windowClass, section: .network,
                    name: "settings-network-permissions-\(windowClass.suffix)",
                    requiredText: [SettingsSection.network.subtitle, "CI status", "api.github.com"],
                    requiredObservations: [String(localized: "Widgets"), String(localized: "Not asked")]
                )
                XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testLauncherPaletteShowsFiltersAndSavedCommands() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        var entry = LauncherEntry()
        entry.name = "Build Project"
        entry.command = "swift build"
        fixture.settings.launcher.entries = [entry]
        var environment = CommandPaletteEnvironment()
        environment.submitApplicationSearch = { _, _, _, generation, publish in
            publish(generation, [LauncherSection(id: .all, title: "Apps", items: [
                LauncherApplicationResult(
                    bundleURL: URL(fileURLWithPath: ApplicationCatalogFilter.finderPath),
                    bundleIdentifier: "com.apple.finder",
                    displayName: "Finder"
                )
            ])], [])
        }
        environment.stopApplicationSearch = {}
        let palette = CommandPaletteController(motionPolicy: fixture.controller.motionPolicy, environment: environment)
        palette.show(wmController: fixture.controller, mode: .applications)
        defer { palette.dismiss(reason: .cancel) }
        do {
            try await render(
                CommandPaletteView(controller: palette, motionPolicy: fixture.controller.motionPolicy),
                fixture: fixture, windowClass: WindowClass(size: CGSize(width: 760, height: 420), dark: true),
                section: .launcher, name: "launcher-palette",
                requiredText: ["All", "Apps", "Saved", "CLI Tools", "Add", "Build Project", "Finder"]
            )
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

    func testUnappliedGestureProposalStaysCurrentWhileItsTabIsHidden() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        do {
            let gestures = fixture.settings.gestures
            gestures.scrollEnabled = true
            gestures.fingerCount = .three
            gestures.workspaceSwipeEnabled = false
            gestures.overviewGestureEnabled = true
            gestures.overviewGestureFingerCount = .four
            gestures.windowMoveEnabled = false
            gestures.windowResizeEnabled = false
            let editor = GestureAssignmentEditor()
            editor.submit(
                .init(action: .move, change: .enabled(true)),
                settings: fixture.settings,
                monitors: Monitor.current()
            )
            XCTAssertNotNil(editor.proposal)
            let navigation = SettingsNavigationModel()
            navigation.section = .mouseTrackpad
            let root = MouseTrackpadSettingsTab(
                settings: fixture.settings, controller: fixture.controller, gestureEditor: editor
            ).environment(navigation)
            try await render(
                root, fixture: fixture, windowClass: windowClasses[1], name: "gesture-proposal-tab-round-trip",
                requiredText: [String(localized: "Cancel")],
                beforeCapture: { _ in
                    let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "OmniWM Settings" })
                    navigation.selectTab("mouse")
                    await self.display(window, appearance: window.effectiveAppearance)
                    gestures.adoptNativeResize.toggle()
                    await self.display(window, appearance: window.effectiveAppearance)
                    navigation.selectTab("trackpad")
                    await self.display(window, appearance: window.effectiveAppearance)
                }
            )
            XCTAssertEqual(editor.proposal?.refreshed, true)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testTabKeepsItsScrollPositionAcrossTabSwitches() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        do {
            let navigation = SettingsNavigationModel()
            navigation.request(SettingsRoute(section: .layouts, tab: "niri"))
            let root = SettingsView(
                settings: fixture.settings, controller: fixture.controller,
                windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
            )
            try await render(
                root, fixture: fixture, windowClass: windowClasses[1], name: "settings-tab-scroll-round-trip",
                requiredText: [],
                beforeCapture: { _ in
                    @MainActor func scrollViews(in view: NSView) -> [NSScrollView] {
                        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
                    }
                    let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "OmniWM Settings" })
                    let content = try XCTUnwrap(window.contentView)
                    let scroll = try XCTUnwrap(scrollViews(in: content).first { view in
                        view.convert(view.bounds, to: content).minX >= 220
                            && (view.documentView?.bounds.height ?? 0) > view.contentView.bounds.height + 300
                    })
                    let clip = scroll.contentView
                    let offset = try XCTUnwrap(scroll.documentView).isFlipped
                        ? 300 : try XCTUnwrap(scroll.documentView).bounds.height - clip.bounds.height - 300
                    clip.scroll(to: CGPoint(x: clip.bounds.minX, y: offset))
                    scroll.reflectScrolledClipView(clip)
                    navigation.selectTab("dwindle")
                    await self.display(window, appearance: window.effectiveAppearance)
                    navigation.selectTab("niri")
                    await self.display(window, appearance: window.effectiveAppearance)
                    XCTAssertNotNil(scroll.window, "Niri's form was rebuilt")
                    XCTAssertEqual(clip.bounds.minY, offset)
                }
            )
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testTabbedPagesOpenedInVisibleWindowKeepTabsLegible() async throws {
        try requireNativeRendering()
        let fixture = try Fixture()
        try await fixture.prepare()
        do {
            let searchResult = try XCTUnwrap(SettingsSearchIndex.results(for: "gap").first {
                $0.route.section == .layouts && $0.route.tab == "spacing"
            })
            let destinations: [(search: String, route: SettingsRoute, tabs: [String])] = [
                ("gap", searchResult.route, ["Spacing", "Niri", "Dwindle"]),
                ("", SettingsRoute(section: .appearance), ["App & Motion", "Window Borders"]),
                ("", SettingsRoute(section: .styles), ["Bar", "Island", "Drawers"]),
                ("", SettingsRoute(section: .menuBar), ["macOS Status Item", "Hidden Bar"]),
                ("", SettingsRoute(section: .monitors), ["Arrangement", "Behavior"]),
                ("", SettingsRoute(section: .mouseTrackpad), ["Trackpad", "Mouse & Focus"])
            ]
            for windowClass in windowClasses {
                for destination in destinations {
                    let navigation = SettingsNavigationModel()
                    navigation.searchText = destination.search
                    let root = SettingsView(
                        settings: fixture.settings, controller: fixture.controller,
                        windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
                    )
                    let name = "settings-open-\(destination.route.section.rawValue)-\(windowClass.suffix)"
                    try await render(
                        root, fixture: fixture, windowClass: windowClass, name: name,
                        requiredText: [],
                        requiredObservations: destination.tabs.map { String(localized: String.LocalizationValue($0)) },
                        beforeCapture: { _ in navigation.request(destination.route) }
                    )
                    XCTAssertEqual(navigation.route, destination.route, name)
                    XCTAssertEqual(navigation.searchText, "", name)
                }
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func render<Content: View>(
        _ content: Content, fixture: Fixture, windowClass: WindowClass, section: SettingsSection? = nil,
        name: String, requiredText: [String], requiredObservations: [String] = [],
        forbiddenText: [String] = [], scrollEditorForm: Bool = false,
        editorFormScrollOffset: CGFloat? = nil,
        beforeCapture: (@MainActor (CGFloat) async throws -> Void)? = nil
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
        try await beforeCapture?(window.backingScaleFactor)
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
        if scrollEditorForm || editorFormScrollOffset != nil {
            try positionEditorForm(in: hosting, offset: editorFormScrollOffset)
            await display(window, appearance: appearance)
        }
        let bitmap = try await capture(window)
        XCTAssertEqual(bitmap.pixelsWide, Int(windowClass.size.width * window.backingScaleFactor), name)
        XCTAssertEqual(bitmap.pixelsHigh, Int(windowClass.size.height * window.backingScaleFactor), name)
        let renderedImage = try XCTUnwrap(bitmap.cgImage)
        var texts = try recognizedText(in: renderedImage)
        XCTAssertFalse(texts.isEmpty, "\(name): no native content was produced")
        var renderedText = normalizedText(texts.joined(separator: " "))
        if section == .styles, requiredText.contains(where: { !renderedText.contains(normalizedText($0)) })
            || !containsObservations(requiredObservations, in: texts)
        {
            let sidebar = 220 * window.backingScaleFactor
            let detail = try XCTUnwrap(renderedImage.cropping(to: CGRect(
                x: sidebar, y: 0, width: CGFloat(bitmap.pixelsWide) - sidebar, height: CGFloat(bitmap.pixelsHigh)
            )))
            texts += try recognizedText(in: detail)
            renderedText = normalizedText(texts.joined(separator: " "))
        }
        for text in requiredText {
            XCTAssertTrue(
                renderedText.contains(normalizedText(text)),
                "\(name): missing \(text); rendered \(texts)"
            )
        }
        XCTAssertTrue(
            containsObservations(requiredObservations, in: texts),
            "\(name): missing individual observations \(requiredObservations); rendered \(texts)"
        )
        for text in forbiddenText {
            XCTAssertFalse(
                renderedText.contains(normalizedText(text)),
                "\(name): unexpected \(text); rendered \(texts)"
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

    private func positionEditorForm(in hosting: NSView, offset requested: CGFloat? = nil) throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let current = (view as? NSScrollView).map { [$0] } ?? []
            return current + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: hosting).first { view in
            let frame = view.convert(view.bounds, to: hosting)
            return frame.minX >= 220 && frame.width > 300
                && (view.documentView?.bounds.height ?? 0) > view.contentView.bounds.height
        }, "The editor must expose a vertical Form scroll view")
        let document = try XCTUnwrap(scroll.documentView)
        let clip = scroll.contentView
        let limit = max(0, document.bounds.height - clip.bounds.height)
        let offset = min(requested ?? (hosting.bounds.width < 1000 ? 300 : 180), limit)
        let original = clip.bounds.origin
        clip.scroll(to: CGPoint(x: original.x, y: document.isFlipped ? offset : limit - offset))
        scroll.reflectScrolledClipView(clip)
        XCTAssertNotEqual(clip.bounds.origin, original)
    }

    private func preparePreviews(
        fixture: Fixture, section: SettingsSection?, dark: Bool, scale: CGFloat
    ) async throws {
        guard section == .styles else { return }
        let configuration = fixture.controller.workspaceBarManager.shellConfiguration
        let profiles = configuration.profiles
        for profile in profiles {
            let config = try await configuration.previewConfig(profile: profile)
            _ = try await ShellSettingsPreview.cachedImage(for: .init(
                config: config, surface: .bar,
                style: ShellSettingsPreview.style(settings: fixture.settings.workspaceBar, config: config),
                scale: scale, dark: dark,
                fullWidth: config.barOverride?.settings.fullWidth ?? fixture.settings.workspaceBar.fullWidth,
                sourceGeneration: configuration.sourceGeneration
            ))
        }
    }

    func requireNativeRendering() throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SETTINGS_UI_RENDER_TESTS"] == "1" else {
            throw XCTSkip("Native settings rendering requires OMNIWM_RUN_SETTINGS_UI_RENDER_TESTS=1")
        }
        _ = try XCTUnwrap(CGPreflightScreenCaptureAccess() ? true : nil, "Screen Recording permission is required")
    }

    private func recognizedText(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.customWords = ["OmniWM", "Niri", "Dwindle", "Luau", "OmniShell"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func containsObservations(_ required: [String], in texts: [String]) -> Bool {
        let observations = Set(texts.map(normalizedText))
        let combined = normalizedText(required.joined(separator: " "))
        return required.allSatisfy { observations.contains(normalizedText($0)) || observations.contains(combined) }
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
        case .styles: [String(localized: "Bar"), String(localized: "Island"), String(localized: "Drawers")]
        default: []
        }
    }

    private func contentLabel(_ section: SettingsSection) -> String {
        switch section {
        case .general: String(localized: "App Language")
        case .appearance: String(localized: "App Appearance")
        case .styles: String(localized: "Bar Widgets")
        case .menuBar: String(localized: "Show Workspace")
        case .network: String(localized: "Built-in Services")
        case .workspaces: String(localized: "Layout Algorithm")
        case .layouts: String(localized: "Spacing")
        case .monitors: String(localized: "Arrangement")
        case .appRules: String(localized: "Add Rule")
        case .overview: String(localized: "Enable Overview")
        case .windowSwitcher: String(localized: "Enable Window Switcher")
        case .hotkeys: String(localized: "System Hyper Trigger")
        case .mouseTrackpad: String(localized: "Trackpad")
        case .launcher: String(localized: "Saved Entries")
        case .quakeTerminal: String(localized: "Enable Quake Terminal")
        case .diagnostics: String(localized: "Health")
        case .reportIssue: String(localized: "Title")
        case .advanced: String(localized: "Reveal Settings File")
        }
    }
}
