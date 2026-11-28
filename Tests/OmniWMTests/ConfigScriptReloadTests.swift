// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptReloadTests: XCTestCase {
    @MainActor private final class Fixture {
        let directory: URL
        let file: URL
        let settings: SettingsStore
        var publications: [[HotkeyBinding]] = []
        lazy var script = ConfigScriptController(fileURL: file, settings: settings) { [weak self] in
            self?.publications.append($0.scriptBindings)
        }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent("init.luau")
            settings = SettingsStore(
                persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
                runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
                autosaveEnabled: false
            )
            settings.hotkeyBindings = []
        }

        func close() {
            script.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        func write(_ source: String, atomic: Bool = false) throws {
            try Data(source.utf8).write(to: file, options: atomic ? .atomic : [])
        }
    }

    private let chord = "Control+Option+J"
    private let otherChord = "Control+Option+K"
    private let fine = 4
    private let coarse = 12

    private func binding(_ chord: String, amount: Int) -> String {
        "omniwm.keymap.set(\"\(chord)\", omniwm.cmd.setContainerPrimarySpan(\"+\(amount)%\"))"
    }

    private func action(_ amount: Int) -> HotkeyCommand {
        .sizing(.setContainerPrimarySpan(.adjustProportion(CGFloat(amount))))
    }

    private func processed(_ fixture: Fixture, edit: () throws -> Void) async throws {
        let completion = expectation(description: "Process resulting init.luau generation")
        completion.assertForOverFulfill = false
        fixture.script.onReloadProcessed = { completion.fulfill() }
        defer { fixture.script.onReloadProcessed = nil }
        try edit()
        await fulfillment(of: [completion], timeout: failureBound)
    }

    func testRealEditsLastGoodRemovalAndRecreation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = binding(chord, amount: fine)
        let second = binding(chord, amount: coarse)
        try await processed(fixture) { fixture.script.start() }
        XCTAssertTrue(fixture.publications.isEmpty)

        try await processed(fixture) { try fixture.write("omniwm.cmd.mistyped()") }
        XCTAssertTrue(fixture.publications.isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:1:"))
        XCTAssertNil(fixture.settings.configNotice)

        try await processed(fixture) { try fixture.write(first, atomic: true) }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(fixture.publications.map { $0.map(\.command) }, [[action(fine)]])
        try await processed(fixture) { try fixture.write(second + "\nomniwm.cmd.mistyped()") }
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("init.luau:2:"))
        XCTAssertEqual(fixture.script.effectiveBindings.map(\.command), [action(fine)])

        try await processed(fixture) { try fixture.write(second, atomic: true) }
        XCTAssertNil(fixture.script.diagnostic)
        try await processed(fixture) { try fixture.write(first) }
        try await processed(fixture) { try FileManager.default.removeItem(at: fixture.file) }
        XCTAssertTrue(fixture.script.effectiveBindings.isEmpty)
        try await processed(fixture) { try fixture.write(second) }
        XCTAssertEqual(
            fixture.publications.map { $0.map(\.command) },
            [[action(fine)], [action(coarse)], [action(fine)], [], [action(coarse)]]
        )
    }

    func testEquivalentSourceChangesNeverRepublish() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = binding(chord, amount: fine)
        let second = binding(otherChord, amount: coarse)
        let source = first + "\n" + second
        try fixture.write(source)
        try await processed(fixture) { fixture.script.start() }
        let initial = fixture.publications
        XCTAssertEqual(initial.count, 1)

        try await processed(fixture) { try fixture.write(source, atomic: true) }
        try await processed(fixture) { try fixture.write("\n" + second + "\n" + binding(
            "option+control+j",
            amount: fine
        )) }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(fixture.publications, initial)
    }

    func testSupersededStartupCannotPublishAfterRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.write(binding(chord, amount: fine))
        try await processed(fixture) {
            fixture.script.start()
            try FileManager.default.removeItem(at: fixture.file)
        }
        XCTAssertTrue(fixture.publications.isEmpty)
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testSupersededLoadAndRemovalCannotReplaceCurrentBindings() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let loader = ConfigScriptLoader()
        let mask = fixture.settings.hyperKeyModifiers.carbonMask
        let absent = await loader.load(fileURL: fixture.file, hyperMask: mask)
        try fixture.write(binding(chord, amount: fine))
        let original = await loader.load(fileURL: fixture.file, hyperMask: mask)
        try fixture.write(binding(chord, amount: coarse), atomic: true)
        try await processed(fixture) { fixture.script.start() }
        XCTAssertFalse(fixture.script.apply(original, hyperMask: mask))
        XCTAssertFalse(fixture.script.apply(absent, hyperMask: mask))
        XCTAssertEqual(fixture.publications.map { $0.map(\.command) }, [[action(coarse)]])
    }

    func testReadErrorPreservesBindingsAndRepairedLinkResumes() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = binding(chord, amount: fine)
        try fixture.write(source)
        try await processed(fixture) { fixture.script.start() }
        let target = fixture.directory.appendingPathComponent("external.luau")
        let replacement = fixture.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: target)
        try await processed(fixture) {
            if Darwin.rename(replacement.path, fixture.file.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        XCTAssertNotNil(fixture.script.diagnostic)
        XCTAssertEqual(fixture.script.effectiveBindings.map(\.command), [action(fine)])
        try await processed(fixture) { try Data(source.utf8).write(to: target, options: .atomic) }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(fixture.publications.count, 1)
    }

    func testFlexMasksOverlappingSettingsFieldsWithoutChangingSavedBindings() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let left = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("LeftControl+Option+J"))
        let modeChord = "J"
        let modeKey = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(modeChord))
        let saved = HotkeyBinding(
            id: "gui.reserved",
            command: .sizing(.balanceSizes),
            trigger: .chord(left),
            modeKey: modeKey
        )
        fixture.settings.hotkeyBindings = [saved]
        let lines = [binding(otherChord, amount: coarse), binding(chord, amount: fine)]
        try fixture.write(lines.joined(separator: "\n"))
        try await processed(fixture) { fixture.script.start() }
        let resolved = fixture.script.resolveBindings(for: [saved])
        XCTAssertEqual(Set(resolved.scriptBindings.map(\.command)), [action(coarse), action(fine)])
        let maskedShortcut = try XCTUnwrap(resolved.bindings.first { $0.id == saved.id })
        XCTAssertEqual(maskedShortcut.binding, .unassigned)
        XCTAssertEqual(maskedShortcut.modeKey, modeKey)
        XCTAssertEqual(resolved.overrides.map(\.bindingID), [saved.id])
        XCTAssertEqual(resolved.overrides.map(\.field), [.shortcut])
        XCTAssertEqual(resolved.overrides.map(\.line), [lines.count])
        XCTAssertEqual(resolved.overrides.map(\.source), [ConfigScriptController.fileName])
        XCTAssertEqual(fixture.settings.hotkeyBindings, [saved])
        XCTAssertNil(fixture.script.diagnostic)

        try await processed(fixture) { try fixture.write(binding(modeChord, amount: fine), atomic: true) }
        let modeOverride = fixture.script.resolveBindings(for: [saved])
        let maskedModeKey = try XCTUnwrap(modeOverride.bindings.first { $0.id == saved.id })
        XCTAssertEqual(maskedModeKey.binding, saved.binding)
        XCTAssertNil(maskedModeKey.modeKey)
        XCTAssertEqual(modeOverride.overrides.map(\.bindingID), [saved.id])
        XCTAssertEqual(modeOverride.overrides.map(\.field), [.modeKey])
        XCTAssertEqual(modeOverride.scriptBindings.map(\.command), [action(fine)])
        XCTAssertEqual(fixture.settings.hotkeyBindings, [saved])
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testHyperChangeReresolvesBeforePublication() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let initial = fixture.settings.hyperKeyModifiers
        defer { fixture.settings.hyperKeyModifiers = initial }
        let source = binding("Hyper+J", amount: fine)
        try fixture.write(source)
        let loaded = await ConfigScriptLoader().load(fileURL: fixture.file, hyperMask: initial.carbonMask)
        let newMask = UInt32(controlKey | optionKey)
        fixture.settings.hyperKeyModifiers = try XCTUnwrap(HyperKeyModifiers(carbonMask: newMask))
        fixture.script.apply(loaded, hyperMask: initial.carbonMask)
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(fixture.script.effectiveBindings.first?.binding.chordBinding?.modifiers, newMask)
    }
}

extension ConfigScriptReloadTests {
    func testFailedImportCanRecoverFromModuleEditAloneAndRemovalClearsBothKinds() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.settings.appRules = []
        let module = fixture.directory.appendingPathComponent("keys.luau")
        try fixture.write("require('./keys')")
        try await processed(fixture) { fixture.script.start() }
        let initialError = try XCTUnwrap(fixture.script.diagnostic)
        XCTAssertTrue(initialError.contains("init.luau:1:"))
        XCTAssertTrue(initialError.contains("keys"))
        XCTAssertTrue(fixture.publications.isEmpty)

        var ruleChanges = 0
        fixture.script.onRulesChanged = { ruleChanges += 1 }
        let bundle = "test.module"
        func moduleSource(_ amount: Int, _ layout: String) -> Data {
            Data(("""
            \(binding(chord, amount: amount))
            omniwm.rule { bundleId = "\(bundle)", layout = "\(layout)" }
            return true
            """).utf8)
        }
        try await processed(fixture) { try moduleSource(fine, "float").write(to: module, options: .atomic) }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(fixture.script.acceptedRules.first?.source, "keys.luau")
        XCTAssertEqual(fixture.settings.effectiveAppRules.first?.effectiveLayoutAction, .float)
        XCTAssertEqual(fixture.publications.map { $0.map(\.command) }, [[action(fine)]])
        XCTAssertEqual(ruleChanges, 1)
        let beforeKey = try XCTUnwrap(fixture.script.acceptedBindings.first)
        let beforeRule = try XCTUnwrap(fixture.script.acceptedRules.first)
        let padding = ["", ""]
        let moved = Data((padding.joined(separator: "\n") + "\n").utf8) + moduleSource(fine, "float")
        try await processed(fixture) { try moved.write(to: module, options: .atomic) }
        XCTAssertEqual(fixture.script.acceptedBindings.first?.line, beforeKey.line + padding.count)
        XCTAssertEqual(fixture.script.acceptedRules.first?.line, beforeRule.line + padding.count)
        XCTAssertEqual(fixture.publications.count, 1)
        XCTAssertEqual(ruleChanges, 1)
        try await processed(fixture) { try moduleSource(coarse, "invalid").write(to: module) }
        XCTAssertTrue(try XCTUnwrap(fixture.script.diagnostic).contains("keys.luau:2:"))
        XCTAssertEqual(fixture.settings.effectiveAppRules.first?.effectiveLayoutAction, .float)
        XCTAssertEqual(fixture.publications.count, 1)
        XCTAssertEqual(ruleChanges, 1)

        try await processed(fixture) { try moduleSource(coarse, "tile").write(to: module, options: .atomic) }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(fixture.settings.effectiveAppRules.first?.effectiveLayoutAction, .tile)
        XCTAssertEqual(ruleChanges, 2)
        let afterEdit = fixture.publications
        try await processed(fixture) { try moduleSource(coarse, "tile").write(to: module, options: .atomic) }
        XCTAssertEqual(fixture.publications, afterEdit)
        XCTAssertEqual(ruleChanges, 2)
        try await processed(fixture) { try FileManager.default.removeItem(at: fixture.file) }
        XCTAssertTrue(fixture.settings.effectiveAppRules.isEmpty)
        XCTAssertEqual(fixture.publications.map { $0.map(\.command) }, [[action(fine)], [action(coarse)], []])
        XCTAssertEqual(ruleChanges, 3)
    }

    func testAtomicSaveInExternalDotfilesDirectoryAndDependencyPruning() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let parent = try SettingsFileAccess.canonicalURL(for: fixture.directory.deletingLastPathComponent())
        let external = parent.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let module = external.appendingPathComponent("keys.luau")
        let link = fixture.directory.appendingPathComponent("keys.luau")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: module)
        try Data((binding(chord, amount: fine) + "\nreturn true").utf8).write(to: module)
        try fixture.write("require('./keys')")
        try await processed(fixture) { fixture.script.start() }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertTrue(fixture.script.observation.isWatchingDirectory(at: external), external.path)
        let stale = await ConfigScriptLoader().load(
            fileURL: fixture.file, hyperMask: fixture.settings.hyperKeyModifiers.carbonMask
        )
        try await processed(fixture) {
            try Data((binding(chord, amount: coarse) + "\nreturn true").utf8).write(to: module, options: .atomic)
        }
        XCTAssertFalse(fixture.script.apply(stale, hyperMask: fixture.settings.hyperKeyModifiers.carbonMask))
        XCTAssertEqual(fixture.publications.map { $0.map(\.command) }, [[action(fine)], [action(coarse)]])
        try await processed(fixture) { try fixture.write(binding(chord, amount: coarse)) }
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertFalse(fixture.script.observation.isWatchingDirectory(at: external))
        XCTAssertEqual(fixture.publications.count, 2)
    }
}
