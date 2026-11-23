// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsControlCoverageTests: XCTestCase {
    private let outsideSettings: [String: Set<SettingsFieldID>] = [
        "Clipboard history is enabled from the command palette.": [.clipboardHistoryEnabled],
        "Clipboard retention and type filters are edited in the file.": [
            .clipboardIgnoredTypes, .clipboardMaxItemBytes, .clipboardMaxItems, .clipboardMaxTotalBytes
        ],
        "Keep Awake and Move Mouse to Focused Window have status-menu controls.": [
            .generalPreventSleepEnabled, .focusMoveMouseToFocusedWindow
        ],
        "The hotkey master switch and scratchpad labels are file preferences.": [
            .generalHotkeysEnabled,
            .scratchpadsLabels
        ],
        "The Hidden Bar page edits the active shell profile. Its base values can be set in the file.": [
            .hiddenBarEnabled, .hiddenBarRehideIntervalSeconds
        ],
        "The Shell editor writes bar style and display overrides to the active profile. These are its file-based defaults.": [
            .monitorBarOverrides,
            .workspaceBarAccentColor,
            .workspaceBarAutoHide,
            .workspaceBarAutoHideHideDelayMilliseconds,
            .workspaceBarAutoHideRevealDelayMilliseconds,
            .workspaceBarBackgroundOpacity,
            .workspaceBarDeduplicateAppIcons,
            .workspaceBarFullWidth,
            .workspaceBarFullWidthNotchMode,
            .workspaceBarHeight,
            .workspaceBarHideEmptyWorkspaces,
            .workspaceBarHideInNativeFullscreen,
            .workspaceBarHoverPreviewsEnabled,
            .workspaceBarInactiveIconOpacity,
            .workspaceBarNotchActiveZoneWidth,
            .workspaceBarNotchMode,
            .workspaceBarNotificationBadgeRefreshIntervalSeconds,
            .workspaceBarNotificationBadges,
            .workspaceBarPosition,
            .workspaceBarReserveLayoutSpace,
            .workspaceBarRevealHoldMilliseconds,
            .workspaceBarRevealModifier,
            .workspaceBarShowAccentHighlights,
            .workspaceBarShowFloatingWindows,
            .workspaceBarShowItemBackgrounds,
            .workspaceBarShowLabels,
            .workspaceBarSolidBlackBackground,
            .workspaceBarSystemStatsButton,
            .workspaceBarTextColor,
            .workspaceBarTransparentBackground,
            .workspaceBarWindowLevel,
            .workspaceBarXOffset,
            .workspaceBarYOffset
        ]
    ]

    func testEverySettingsFieldHasAMarkedControlOrADocumentedOwner() throws {
        let model = try SettingsSchemaRecorder.inventory()
        let leaves = model.paths()
        let cases = Dictionary(uniqueKeysWithValues: SettingsFieldID.allCases
            .map { (String(describing: $0), $0.rawValue) })
        let references = #"\.settingsField\s*\([^)]*\)|\bfield:\s*\.init\([^)]*\)|\bfield:\s*\.\w+|SettingsFieldID\.\w+"#
        let markUses = try NSRegularExpression(pattern: references)
        let identifiers = try NSRegularExpression(pattern: #"\.(\w+)"#)
        var used: Set<String> = []
        for (_, text) in try uiFiles() {
            let contents = text as NSString
            for use in markUses.matches(in: text, range: NSRange(location: 0, length: contents.length)) {
                for id in identifiers.matches(in: text, range: use.range) {
                    if let path = cases[contents.substring(with: id.range(at: 1))] {
                        used.insert(path)
                    }
                }
            }
        }
        let excepted = Set(outsideSettings.values.flatMap { $0.map(\.rawValue) })
        XCTAssertEqual(used.intersection(excepted), [], "Remove the exception when a control is added")
        let annotated = expanded(used, in: leaves)
        let external = expanded(excepted, in: leaves)
        XCTAssertEqual(
            leaves.subtracting(annotated.union(external)).sorted(),
            [],
            "Annotate the control with its generated ID, or document where the preference is edited"
        )
        XCTAssertEqual(excepted.filter { expanded([$0], in: leaves).isEmpty }, [], "Obsolete coverage exception")
    }

    private func expanded(_ paths: Set<String>, in leaves: Set<String>) -> Set<String> {
        var result = paths.intersection(leaves)
        for parent in paths {
            let color = Set(["red", "green", "blue", "alpha"].map { parent + "." + $0 })
            if color.isSubset(of: leaves) { result.formUnion(color) }
        }
        return result
    }

    func testListEditorsNameFieldsFromTheirDecodedRow() throws {
        let lists = try SettingsSchemaRecorder.inventory().recordLists()
        let ids = Dictionary(uniqueKeysWithValues: SettingsFieldID.allCases
            .map { (String(describing: $0), $0.rawValue) })
        let files = try uiFiles()
        let sharedFit = try capture(
            #"SingleWindowFitControls\(\s*label:[^\n]*,\s*field:\s*\.(\w+)"#,
            in: files.map(\.1).joined(separator: "\n")
        )
        let calls =
            try NSRegularExpression(
                pattern: #"(?:(?:\.settingsField|\bfield:\s*\.init)\s*)\(([^,)]*),[^)]*?\bleaf:\s*([^)]*)\)"#
            )
        var used: [String: Set<String>] = [:]
        for (url, text) in files {
            let source = text as NSString
            for call in calls.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let argument = source.substring(with: call.range(at: 1))
                let names = url.lastPathComponent == "SingleWindowFitControls.swift" && argument == "field"
                    ? sharedFit : try capture(#"\.(\w+)"#, in: argument)
                let leaves = try capture(#""(\w+)""#, in: source.substring(with: call.range(at: 2)))
                let parents = names.compactMap { ids[$0] }.filter { lists[$0] != nil }
                XCTAssertFalse(parents.isEmpty, "\(url.lastPathComponent): no decoded list for \(argument)")
                for path in parents { used[path, default: []].formUnion(leaves) }
            }
        }
        for (path, members) in lists {
            let annotated = used[path] ?? []
            XCTAssertEqual(annotated.subtracting(members), [], "Unknown row annotation on \(path)")
            let uncovered = members.subtracting(annotated).filter { rowException(path: path, member: $0) == nil }
            XCTAssertEqual(uncovered.sorted(), [], "Add the row control or its owner for \(path)")
        }
    }

    private func rowException(path: String, member: String) -> String? {
        guard let id = SettingsFieldID(rawValue: path) else { return nil }
        if outsideSettings.values
            .contains(where: { $0.contains(id) }) { return "The collection is edited outside Settings." }
        if member == "id" { return "The native row identifier is assigned on creation." }
        switch id {
        case .monitorDwindleOverrides,
             .monitorGapOverrides,
             .monitorNiriOverrides,
             .monitorOrientationOverrides:
            if ["monitorDisplayId", "monitorDisplayUUID", "monitorName"]
                .contains(member) { return "The monitor picker selects the hardware identity." }
        case .workspaces where member == "name": return "The workspace ID is displayed as read-only."
        case .monitorsRanking: return "Monitor Roles reorders complete display identities and marks the ranking."
        case .shellPermissionsPrograms: return "Allow, Deny, and Reset replace the complete program approval and mark the row."
        case .shellPermissionsWidgets where ["role", "name", "source"].contains(member): return "These fields identify the requesting widget."
        default: break
        }
        return nil
    }

    private func capture(_ pattern: String, in text: String) throws -> [String] {
        let source = text as NSString
        return try NSRegularExpression(pattern: pattern).matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        .map { source.substring(with: $0.range(at: 1)) }
    }

    func testPersistentSlidersGoThroughTheDraftControl() throws {
        let slider = try NSRegularExpression(pattern: #"\bSlider\s*\("#)
        let native = try uiFiles().compactMap { url, text -> String? in
            let range = NSRange(text.startIndex..., in: text)
            return slider.firstMatch(in: text, range: range) == nil ? nil : url.lastPathComponent
        }
        XCTAssertEqual(
            Set(native),
            ["SettingsValueSlider.swift", "AppWindowCornerSettings.swift"],
            "The second slider writes macOS global window corner preferences."
        )
    }

    private func uiFiles() throws -> [(URL, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources/OmniWM/UI"),
            includingPropertiesForKeys: nil
        ))
        return try files.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try (url, String(contentsOf: url, encoding: .utf8))
        }
    }
}
