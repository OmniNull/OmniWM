// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SettingsFormulaTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let storage: SettingsFilePersistence
        let settings: SettingsStore

        init(_ source: String, deferred: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            storage = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: deferred)
            try Data(source.utf8).write(to: storage.fileURL)
            settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
            storage.confirmation.canPresent = { true }
        }

        var source: String {
            get throws { try String(contentsOf: storage.fileURL, encoding: .utf8) }
        }

        var question: SettingsFormulaConfirmation
            .Question
        {
            get throws { try XCTUnwrap(storage.confirmation.question) }
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testDragOffersOneReplacementOnReleaseAndCancelPreservesLiveStateAndEveryByte() throws {
        let source = "-- gap 🚲\r\nreturn { gaps = { size = (4 * 2), -- keep this comment\r\n} }\r\n"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        let settings = fixture.settings
        let original = settings.gaps.size
        let positions = [original + 1, original + 2, original + 3]
        var draft = SettingsSliderDraft()
        draft.begin(at: original)
        for position in positions {
            XCTAssertTrue(draft.update(position))
            XCTAssertNil(fixture.storage.confirmation.question)
            XCTAssertEqual(settings.gaps.size, original)
        }
        settings.gaps.size = try XCTUnwrap(draft.finish(at: original))
        XCTAssertNil(draft.finish(at: original))
        let first = try fixture.question
        XCTAssertTrue(first.message
            .contains("Line 2 calculates gaps.size. Replace 4 * 2 with \(Int(try XCTUnwrap(positions.last)))?"))
        XCTAssertEqual(try fixture.source, source)
        fixture.storage.confirmation.answer(first.id, replace: false)
        XCTAssertEqual(settings.gaps.size, original)
        XCTAssertNil(fixture.storage.confirmation.question)
        XCTAssertEqual(try fixture.source, source)

        let final = original + 2
        settings.gaps.size = final
        let next = try fixture.question
        fixture.storage.confirmation.answer(first.id, replace: true)
        XCTAssertEqual(fixture.storage.confirmation.question?.id, next.id)
        fixture.storage.confirmation.answer(next.id, replace: true)
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(settings.gaps.size, final)
        XCTAssertEqual(try fixture.source, source.replacingOccurrences(of: "4 * 2", with: String(Int(final))))
    }

    func testConfirmedNormalSaveUsesTheDeferredWriterAndSharedLocalStaysIntact() async throws {
        let source = "local step = 4\nlocal config: any = { gaps = { size = step * 2, outer = { left = step } } }\nreturn config"
        let fixture = try Fixture(source, deferred: true)
        defer { fixture.close() }
        let size = fixture.settings.gaps.size + 2
        let left = fixture.settings.gaps.outerGapLeft
        let question = try await waitForQuestion(in: fixture) { fixture.settings.gaps.size = size }
        XCTAssertTrue(question.message.contains("Line 2 calculates gaps.size"))
        let committed = expectation(description: "Confirmed formula edit committed")
        fixture.storage.setSaveNoticeHandler { notice in
            XCTAssertNil(notice)
            committed.fulfill()
        }
        fixture.storage.confirmation.answer(question.id, replace: true)
        await fulfillment(of: [committed], timeout: failureBound)
        XCTAssertEqual(try fixture.source, source.replacingOccurrences(of: "step * 2", with: String(Int(size))))
        XCTAssertEqual(fixture.settings.gaps.size, size)
        XCTAssertEqual(fixture.settings.gaps.outerGapLeft, left)
    }

    func testCalculatedGroupListsSiblingsAndReplacesOnlyTheGroup() throws {
        let helper = "local function makeOuter() return { left = 1, right = 2, top = 3, bottom = 4 } end\n"
        let source = helper + "return { gaps = { size = 9 * 2, outer = makeOuter(), -- keep outer\n} }\n"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        let original = fixture.settings.gaps.export()
        let left = original.outer.left + 1
        fixture.settings.gaps.outerGapLeft = left
        let question = try fixture.question
        for text in [
            "gaps.outer",
            "makeOuter()",
            "gaps.outer.left = \(Int(left))",
            "bottom = \(Int(original.outer.bottom))",
            "right = \(Int(original.outer.right))",
            "top = \(Int(original.outer.top))"
        ] {
            XCTAssertTrue(question.message.contains(text), text)
        }
        XCTAssertEqual(try fixture.source, source)
        fixture.storage.confirmation.answer(question.id, replace: true)
        let saved = try fixture.source
        XCTAssertTrue(saved.hasPrefix(helper + "return { gaps = { size = 9 * 2, outer = {"))
        XCTAssertTrue(saved.hasSuffix(", -- keep outer\n} }\n"))
        var expected = original
        expected.outer.left = left
        XCTAssertEqual(fixture.settings.gaps.export(), expected)
        XCTAssertEqual(try SettingsLuauDocument(Data(saved.utf8)).export.gaps, expected)
        fixture.settings.gaps.outerGapRight += 1
        XCTAssertNil(fixture.storage.confirmation.question)
        XCTAssertNil(fixture.settings.configNotice)
    }

    func testIPCServiceChangesOnlyAfterConsent() throws {
        let source = "return { general = { ipcEnabled = not true } }"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        var serviceChanges: [Bool] = []
        var accepted = 0
        fixture.settings.onIPCEnabledChanged = { serviceChanges.append($0) }
        fixture.settings.onConfirmedSettingsEdit = { accepted += 1 }
        fixture.settings.onExternalSettingsReloaded = { XCTFail("A Settings edit is local") }
        fixture.settings.ipcEnabled = true
        let cancelled = try fixture.question
        fixture.storage.confirmation.answer(cancelled.id, replace: false)
        XCTAssertFalse(fixture.settings.ipcEnabled)
        XCTAssertEqual(try fixture.source, source)
        XCTAssertTrue(serviceChanges.isEmpty)
        XCTAssertEqual(accepted, 0)
        fixture.settings.ipcEnabled = true
        let approved = try fixture.question
        fixture.storage.confirmation.answer(approved.id, replace: true)
        XCTAssertTrue(fixture.settings.ipcEnabled)
        XCTAssertEqual(serviceChanges, [true])
        XCTAssertEqual(accepted, 1)
    }

    func testFormulaPreviewIncludesEveryDerivedChangeBeforeApplyingIt() throws {
        let file = """
        local other = 0
        local function inner()
            other = 3
            return 8
        end
        return { gaps = { size = inner(), outer = { left = other } } }
        """
        let fixture = try Fixture(file)
        defer { fixture.close() }
        let original = fixture.settings.gaps.export()
        let requested = original.size + 1
        fixture.settings.gaps.size = requested
        let question = try fixture.question
        XCTAssertTrue(question.message.contains("gaps.outer.left: \(Int(original.outer.left)) → 0"))
        XCTAssertEqual(fixture.settings.gaps.export(), original)
        fixture.storage.confirmation.answer(question.id, replace: true)
        XCTAssertNil(fixture.settings.configNotice)
        XCTAssertEqual(
            try fixture.source,
            file.replacingOccurrences(of: "size = inner()", with: "size = \(Int(requested))")
        )
        XCTAssertEqual(fixture.settings.gaps.size, requested)
        XCTAssertEqual(fixture.settings.gaps.outerGapLeft, 0)
    }

    func testAnimationControlKeepsLivePolicyUntilConfirmed() throws {
        let fixture = try Fixture("return { general = { animationsEnabled = not false } }")
        defer { fixture.close() }
        let controller = WMController(settings: fixture.settings)
        let original = fixture.settings.animationsEnabled
        controller.setAnimationsEnabled(original, persist: false)
        fixture.settings.onConfirmedSettingsEdit = { [weak controller] in
            controller?.setAnimationsEnabled(fixture.settings.animationsEnabled, persist: false)
        }
        defer { fixture.settings.onConfirmedSettingsEdit = nil }
        controller.setAnimationsEnabled(!original)
        let question = try fixture.question
        XCTAssertEqual(controller.motionPolicy.userAnimationsEnabled, original)
        fixture.storage.confirmation.answer(question.id, replace: true)
        XCTAssertEqual(controller.motionPolicy.userAnimationsEnabled, !original)
    }

    func testGestureAvailabilityNeverObservesAnUnapprovedToggle() throws {
        let source = """
        return { gestures = {
            scrollEnabled = not true, workspaceSwipeEnabled = false, overviewGestureEnabled = false,
            windowMoveEnabled = false, windowResizeEnabled = false,
        } }
        """
        let fixture = try Fixture(source)
        defer { fixture.close() }
        var availability: [Bool] = []
        var pointerStates: [Bool] = []
        fixture.settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }
        fixture.settings.onPointerSettingsChanged = { pointerStates.append(fixture.settings.gestures.scrollEnabled) }
        defer { fixture.settings.onPointerSettingsChanged = nil }
        fixture.settings.gestures.scrollEnabled = true
        let question = try fixture.question
        XCTAssertTrue(availability.isEmpty)
        XCTAssertFalse(pointerStates.contains(true))
        fixture.storage.confirmation.answer(question.id, replace: true)
        XCTAssertTrue(fixture.settings.effectiveTrackpadGesturesEnabled)
        XCTAssertEqual(availability, [true])
    }

    func testCancellingFormulaPreservesTheEarlierPendingLiteralEdit() async throws {
        let source = "return { gaps = { size = 4 * 2, outer = { left = 1 } } }"
        let fixture = try Fixture(source, deferred: true)
        defer { fixture.close() }
        let next = fixture.settings.gaps.outerGapLeft + 1
        let question = try await waitForQuestion(in: fixture) {
            fixture.settings.gaps.outerGapLeft = next
            fixture.settings.gaps.size += 1
        }
        XCTAssertFalse(question.message.contains("gaps.outer.left"))
        fixture.storage.confirmation.answer(question.id, replace: false)
        fixture.storage.flushNow()
        XCTAssertEqual(fixture.settings.gaps.outerGapLeft, next)
        XCTAssertEqual(try fixture.source, source.replacingOccurrences(of: "left = 1", with: "left = \(Int(next))"))
    }

    private func waitForQuestion(
        in fixture: Fixture,
        edit: () -> Void
    ) async throws -> SettingsFormulaConfirmation.Question {
        let presented = expectation(description: "Validated formula replacement ready for the window")
        fixture.storage.setSaveNoticeHandler { notice in
            XCTAssertNil(notice)
            if fixture.storage.confirmation.question != nil || notice != nil { presented.fulfill() }
        }
        defer { fixture.storage.setSaveNoticeHandler { _ in } }
        edit()
        await fulfillment(of: [presented], timeout: failureBound)
        return try fixture.question
    }

    func testDuplicateAndDynamicKeysNeedGroupConsentAndKeepInteriorComments() throws {
        for assignment in ["left = 1, left = 2", "left = 1, [name] = 2"] {
            let prefix = "local name = 'left'\nreturn { gaps = { size = 2 * 9, outer = "
            let tail = ", -- trailing\n} }"
            let fixture = try Fixture(prefix + "{ \(assignment), -- inside\n right = 3 }" + tail)
            defer { fixture.close() }
            let left = fixture.settings.gaps.outerGapLeft + 1
            fixture.settings.gaps.outerGapLeft = left
            let question = try fixture.question
            XCTAssertTrue(question.message.contains(assignment))
            XCTAssertTrue(question.message.contains("gaps.outer.left"))
            fixture.storage.confirmation.answer(question.id, replace: true)
            let saved = try fixture.source
            XCTAssertTrue(saved.hasPrefix(prefix))
            XCTAssertTrue(saved.contains("-- inside\n"))
            XCTAssertTrue(saved.hasSuffix(tail))
            XCTAssertEqual(try SettingsLuauDocument(Data(saved.utf8)).export.gaps.outer.left, left)
        }
    }

    func testExternalEditVoidsConsentIncludingWhenValuesAreEqualOrTheObserverHasNotRun() throws {
        let source = "return {gaps = {size = 4 * 2}}"
        for observed in [true, false] {
            let fixture = try Fixture(source)
            defer { fixture.close() }
            let original = fixture.settings.gaps.size
            fixture.settings.gaps.size = original + 1
            let question = try fixture.question
            let newer = "-- external edit\n" + source
            try Data(newer.utf8).write(to: fixture.storage.fileURL, options: .atomic)
            if observed {
                fixture.storage.handlePossibleSettingsFileChange()
                XCTAssertNil(fixture.storage.confirmation.question)
            }
            fixture.storage.confirmation.answer(question.id, replace: true)
            XCTAssertEqual(try fixture.source, newer)
            XCTAssertEqual(fixture.settings.gaps.size, original)
            XCTAssertNil(fixture.storage.confirmation.question)
        }
    }

    func testOpaqueAndConditionalRootsBecomeOneEditableTableWithExplicitConsent() throws {
        let prefix = "local function group() return {gaps = {size = 4 * 2}} end\nlocal assembled = group()\n"
        let condition = "if assembled.gaps.size > 0 then return assembled end\n"
        for body in ["return assembled", condition + "return group()"] {
            let fixture = try Fixture(prefix + body)
            defer { fixture.close() }
            let next = fixture.settings.gaps.size + 1
            fixture.settings.gaps.size = next
            let question = try fixture.question
            XCTAssertTrue(question.message.contains("all returned settings"), question.message)
            XCTAssertTrue(question.message.contains("workspaces ="))
            fixture.storage.confirmation.answer(question.id, replace: true)
            var saved = try fixture.source
            XCTAssertTrue(saved.contains(prefix))
            XCTAssertEqual(fixture.settings.gaps.size, next)
            let second = next + 1
            fixture.settings.gaps.size = second
            XCTAssertNil(fixture.settings.configNotice)
            XCTAssertNil(fixture.storage.confirmation.question)
            saved = try fixture.source
            XCTAssertEqual(try SettingsLuauDocument(Data(saved.utf8)).export.gaps.size, second)
            XCTAssertEqual(saved.components(separatedBy: "workspaces =").count - 1, 1)
        }
    }
}
