// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC
import XCTest

final class IPCRuleValidatorTests: XCTestCase {
    func testEmptyBundleWithAppNameIsValid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "", appNameSubstring: "VMD", layout: .float)
        )
        XCTAssertNil(report.identifierError)
        XCTAssertNil(report.bundleIdError)
        XCTAssertTrue(report.isValid)
    }

    func testEmptyBundleWithTitleIsValid() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "", titleSubstring: "Main", layout: .float)
        )
        XCTAssertNil(report.identifierError)
        XCTAssertTrue(report.isValid)
    }

    func testInvalidDefinitionsReportTheirError() {
        let cases: [(label: String, rule: IPCRuleDefinition, error: KeyPath<IPCRuleValidationReport, String?>)] = [
            ("empty bundle without matchers", IPCRuleDefinition(bundleId: ""), \.identifierError),
            (
                "empty bundle with ax matcher only",
                IPCRuleDefinition(bundleId: "", axSubrole: "AXStandardWindow", layout: .float),
                \.identifierError
            ),
            ("malformed bundle", IPCRuleDefinition(bundleId: "not a bundle id"), \.bundleIdError),
            ("matcher without effect", IPCRuleDefinition(bundleId: "com.test.app"), \.effectError)
        ]
        for testCase in cases {
            let report = IPCRuleValidator.validate(testCase.rule)
            XCTAssertNotNil(report[keyPath: testCase.error], testCase.label)
            XCTAssertFalse(report.isValid, testCase.label)
        }
    }

    func testEmptyBundleStringHasNoFormatError() {
        XCTAssertNil(IPCRuleValidator.bundleIdError(for: ""))
    }

    func testWorkspaceAssignmentCountsAsEffect() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", assignToWorkspace: "2")
        )
        XCTAssertNil(report.effectError)
        XCTAssertTrue(report.isValid)
    }

    func testBothTitleMatchersRejected() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", titleSubstring: "Main", titleRegex: "^Main$", layout: .float)
        )
        XCTAssertNotNil(report.titleMatcherError)
        XCTAssertFalse(report.isValid)
    }

    func testMinimumSizeValidationPreservesEveryBoundary() {
        let cases: [(width: Double?, height: Double?, valid: Bool)] = [
            (0, nil, false), (-10, nil, false), (.nan, nil, false),
            (.infinity, nil, false), (-.infinity, nil, false), (-0.0, nil, false),
            (nil, -1, false), (nil, .infinity, false),
            (400, 300, true), (1, nil, true), (.leastNonzeroMagnitude, nil, true)
        ]
        for row in cases {
            let report = IPCRuleValidator.validate(
                IPCRuleDefinition(bundleId: "com.test.app", minWidth: row.width, minHeight: row.height)
            )
            XCTAssertEqual(
                report.minSizeError == nil,
                row.valid,
                "width=\(String(describing: row.width)) height=\(String(describing: row.height))"
            )
            XCTAssertEqual(report.isValid, row.valid)
        }
    }

    func testInitialContainerPrimarySpanInclusiveBoundsAccepted() {
        for value in [0.05, 0.5, 1.0] {
            let report = IPCRuleValidator.validate(
                IPCRuleDefinition(bundleId: "com.test.app", initialContainerPrimarySpan: value)
            )
            XCTAssertNil(report.initialContainerPrimarySpanError)
            XCTAssertNil(report.effectError)
            XCTAssertTrue(report.isValid)
        }
    }

    func testInvalidInitialContainerPrimarySpanRejectedWithoutCountingAsEffect() {
        for value in [0.049, 1.001, .nan, .infinity, -.infinity] {
            let report = IPCRuleValidator.validate(
                IPCRuleDefinition(bundleId: "com.test.app", initialContainerPrimarySpan: value)
            )
            XCTAssertNotNil(report.initialContainerPrimarySpanError)
            XCTAssertNotNil(report.effectError)
            XCTAssertFalse(report.isValid)
        }
    }

    func testInvalidInitialContainerPrimarySpanDoesNotHideAnotherEffect() {
        let report = IPCRuleValidator.validate(
            IPCRuleDefinition(bundleId: "com.test.app", layout: .float, initialContainerPrimarySpan: 1.001)
        )
        XCTAssertNotNil(report.initialContainerPrimarySpanError)
        XCTAssertNil(report.effectError)
        XCTAssertFalse(report.isValid)
    }

    func testInitialContainerPrimarySpanIPCModelsRoundTrip() throws {
        let definition = IPCRuleDefinition(bundleId: "com.test.app", initialContainerPrimarySpan: 0.5)
        let definitionData = try JSONEncoder().encode(definition)
        XCTAssertEqual(try JSONDecoder().decode(IPCRuleDefinition.self, from: definitionData), definition)

        let snapshot = IPCRuleSnapshot(
            id: "x",
            position: 1,
            bundleId: "com.test.app",
            layout: .auto,
            initialContainerPrimarySpan: 0.5,
            specificity: 2,
            isValid: true
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(IPCRuleSnapshot.self, from: snapshotData), snapshot)
    }

    func testInitialContainerPrimarySpanManifestOption() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.ruleDefinitionOptionDescriptors.first {
                $0.flag == "--initial-container-primary-span"
            }
        )
        XCTAssertEqual(descriptor.valuePlaceholder, "<proportion>")
        XCTAssertFalse(
            IPCAutomationManifest.ruleDefinitionOptionDescriptors.contains {
                $0.flag == "--initial-column-width"
            }
        )
    }

    func testLegacyInitialColumnWidthWireFieldDoesNotAliasPrimarySpan() throws {
        let data = Data(
            #"{"bundleId":"com.test.app","layout":"float","initialColumnWidth":0.5}"#.utf8
        )

        let decoded = try JSONDecoder().decode(IPCRuleDefinition.self, from: data)

        XCTAssertNil(decoded.initialContainerPrimarySpan)
    }

    func testMessagesAggregateAllErrors() {
        let report = IPCRuleValidator.validate(IPCRuleDefinition(bundleId: ""))
        XCTAssertEqual(report.messages, [
            "Set a bundle ID, app name, or title matcher",
            "Set a layout, workspace, initial container primary span, or minimum size — this rule has no effect"
        ])
        XCTAssertEqual(report.messages, report.messages.filter { !$0.isEmpty })
        XCTAssertFalse(report.messages.isEmpty)
        XCTAssertTrue(report.messages.contains { $0 == report.identifierError })
        let complete = IPCRuleValidationReport(
            bundleIdError: "bundle",
            invalidRegexMessage: "regex",
            identifierError: "identifier",
            titleMatcherError: "title",
            initialContainerPrimarySpanError: "span",
            effectError: "effect",
            minSizeError: "size"
        )
        XCTAssertEqual(complete.messages, ["bundle", "regex", "identifier", "title", "span", "effect", "size"])
    }

    func testSnapshotCodecToleratesMissingValidationMessages() throws {
        let json = """
        {"id":"x","position":1,"bundleId":"com.test.app","layout":"float","specificity":2,"isValid":true}
        """
        let snapshot = try JSONDecoder().decode(IPCRuleSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.validationMessages, [])

        let roundTripped = try JSONDecoder().decode(
            IPCRuleSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(roundTripped, snapshot)
    }

    func testBundleIdTrimsSurroundingWhitespace() {
        XCTAssertNil(IPCRuleValidator.bundleIdError(for: " com.example.app "))
        XCTAssertNil(IPCRuleValidator.bundleIdError(for: "com.example.app\n"))
    }

    func testBundleIdRejectsLeadingAndTrailingDots() {
        XCTAssertNotNil(IPCRuleValidator.bundleIdError(for: "com.app."))
        XCTAssertNotNil(IPCRuleValidator.bundleIdError(for: ".com.app"))
    }

    func testBundleIdRegexBoundaries() {
        XCTAssertNil(IPCRuleValidator.bundleIdError(for: "a"))
        XCTAssertNil(IPCRuleValidator.bundleIdError(for: "1"))
        XCTAssertNil(IPCRuleValidator.bundleIdError(for: "com.app-slot"))
        XCTAssertNotNil(IPCRuleValidator.bundleIdError(for: "com.app-"))
        XCTAssertNotNil(IPCRuleValidator.bundleIdError(for: "com.app slot"))
    }

    func testBundleIdRequiresWholeASCIIIdentifier() {
        let invalidIdentifiers = [
            "com.app\nother", "com.app\r\nother", "com.app\u{2028}other",
            "com.ä", "com.Ａ", "com.a\u{0301}", "com.😀", "com.app\u{0000}",
            "com..app", "com.-app", "com.app_name", "-com.app"
        ]
        for identifier in invalidIdentifiers {
            XCTAssertEqual(IPCRuleValidator.bundleIdError(for: identifier), "Invalid bundle ID format", identifier)
        }
    }

    func testBundleIdPreservesWhitespaceTrimmingAndMixedSeparators() {
        for identifier in [" \t\r\n", "\u{2003}com.App-123\u{2028}", "a-b.c-D9", "COM9"] {
            XCTAssertNil(IPCRuleValidator.bundleIdError(for: identifier), identifier)
        }
    }

    func testValidRegexReturnsNoMessage() {
        XCTAssertNil(IPCRuleValidator.invalidRegexMessage(for: "^foo.*bar$"))
        XCTAssertNil(IPCRuleValidator.invalidRegexMessage(for: nil))
        XCTAssertNil(IPCRuleValidator.invalidRegexMessage(for: "   "))
    }

    func testInvalidRegexReturnsMessage() {
        XCTAssertNotNil(IPCRuleValidator.invalidRegexMessage(for: "["))
    }
}
