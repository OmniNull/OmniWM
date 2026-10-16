// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class SettingsConfigNoticeTests: XCTestCase {
    func testStartupRejectionShowsFileAndParserReasonWithoutTakingFocus() throws {
        let keyWindow = NSApp?.keyWindow
        let fixture = try Fixture(initialText: "monitorGapOverrides = []\n[[monitorGapOverrides]]\n")
        defer { fixture.close() }
        let panel = try fixture.panel()
        let issue = try XCTUnwrap(fixture.notices.issue)

        XCTAssertTrue(issue.message.contains(fixture.persistence.fileURL.path))
        XCTAssertTrue(issue.message.contains("line 2"))
        XCTAssertTrue(issue.message.contains("column 1"))
        XCTAssertTrue(issue.message.contains("cannot redefine existing array 'monitorGapOverrides'"))
        XCTAssertTrue(issue.message.contains("active settings were not changed"))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(NSApp?.keyWindow === keyWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(fixture.registry.hasVisibleWindow)
        XCTAssertFalse(fixture.registry.isCaptureEligible(windowNumber: panel.windowNumber))
        XCTAssertTrue(fixture.registry.contains(window: panel))
    }

    func testDismissedErrorStaysDismissedUntilItChangesOrClears() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertNil(fixture.notices.issue)
        XCTAssertTrue(fixture.registry.visibleWindows().isEmpty)
        let originalSettings = fixture.settings.toExport()
        try fixture.edit("[general\n")
        let panel = try fixture.panel()
        let firstIssue = fixture.notices.issue
        fixture.notices.dismiss()

        fixture.notices.refresh()
        fixture.persistence.handlePossibleSettingsFileChange()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNotNil(fixture.settings.configNotice)
        XCTAssertEqual(fixture.settings.toExport(), originalSettings)

        try fixture.edit("bad = [\n")
        XCTAssertTrue(try fixture.panel() === panel)
        XCTAssertNotEqual(fixture.notices.issue, firstIssue)

        try fixture.edit(String(decoding: SettingsTOMLCodec.encode(originalSettings), as: UTF8.self))
        XCTAssertNil(fixture.notices.issue)
        XCTAssertNil(fixture.settings.configNotice)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(fixture.registry.contains(window: panel))

        try fixture.edit("[general\n")
        XCTAssertTrue(try fixture.panel().isVisible)
        XCTAssertEqual(fixture.notices.issue, firstIssue)
    }

    func testOpeningRejectedFileReportsFailureAndKeepsNoticeVisible() throws {
        var openedURL: URL?
        let fixture = try Fixture(initialText: "[general\n", openFile: {
            openedURL = $0
            return false
        })
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.persistence.fileURL)
        fixture.notices.openSettingsFile()

        XCTAssertEqual(openedURL, fixture.persistence.fileURL)
        guard case .error = fixture.notices.fileStatus else {
            return XCTFail("Expected opening failure to be visible")
        }
        XCTAssertTrue(try fixture.panel().isVisible)
        XCTAssertEqual(try Data(contentsOf: fixture.persistence.fileURL), original)
    }

    func testOpeningRejectedFileKeepsTheDiagnosticAvailable() throws {
        let fixture = try Fixture(initialText: "[general\n", openFile: { _ in true })
        defer { fixture.close() }
        fixture.notices.openSettingsFile()
        XCTAssertEqual(fixture.notices.fileStatus, .opened)
        XCTAssertTrue(try fixture.panel().isVisible)
    }

    func testUnsupportedSchemaShowsBlockedWriteNoticeAndClearsAfterCorrection() throws {
        let original = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let future = original.replacingOccurrences(of: "schemaVersion = 4", with: "schemaVersion = 5")
        let fixture = try Fixture(initialText: future)
        defer { fixture.close() }
        XCTAssertTrue(try fixture.panel().isVisible)
        XCTAssertTrue(fixture.settings.settingsWritesBlocked)
        guard case .settingsPersistenceBlocked = fixture.notices.issue?.kind else {
            return XCTFail("Expected blocked settings notice")
        }

        try fixture.edit(original)
        XCTAssertNil(fixture.notices.issue)
        XCTAssertFalse(fixture.settings.settingsWritesBlocked)
        XCTAssertTrue(fixture.registry.visibleWindows().isEmpty)
    }

    func testClosingNoticeReleasesItsRegisteredSurface() throws {
        weak var panel: NSPanel?
        let registry = try autoreleasepool {
            let fixture = try Fixture(initialText: "[general\n")
            defer { fixture.close() }
            panel = try fixture.panel()
            fixture.notices.close()
            XCTAssertFalse(try XCTUnwrap(panel).isVisible)
            XCTAssertFalse(fixture.registry.contains(window: panel))
            return fixture.registry
        }
        XCTAssertNil(panel)
        XCTAssertTrue(registry.visibleWindows().isEmpty)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let persistence: SettingsFilePersistence
        let settings: SettingsStore
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let notices: SettingsConfigNoticeController

        init(initialText: String? = nil, openFile: @escaping (URL) -> Bool = { _ in false }) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SettingsConfigNoticeTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let initialText {
                try Data(initialText.utf8).write(to: directory.appendingPathComponent("settings.toml"))
            }
            persistence = SettingsFilePersistence(
                directory: directory, startWatching: false, deferSaves: false, monitorProvider: { [] }
            )
            settings = SettingsStore(
                persistence: persistence,
                runtimeState: RuntimeStateStore(
                    directory: directory.appendingPathComponent("state"),
                    deferSaves: false
                ),
                autosaveEnabled: false
            )
            notices = SettingsConfigNoticeController(
                settings: settings,
                ownedWindowRegistry: registry,
                openFile: openFile
            )
            settings.onConfigNoticeChanged = { [weak notices] in notices?.refresh() }
            notices.refresh()
        }

        func edit(_ text: String) throws {
            try Data(text.utf8).write(to: persistence.fileURL, options: .atomic)
            persistence.handlePossibleSettingsFileChange()
        }

        func panel() throws -> NSPanel {
            try XCTUnwrap(registry.visibleWindows(kind: .utility).first as? NSPanel)
        }

        func close() {
            notices.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
