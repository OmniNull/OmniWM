// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppThemeFileTransactionTests: XCTestCase {
    private var sandbox: AppThemeSandbox!
    private var fake: AppThemeFakeEnvironment!

    override func setUpWithError() throws {
        sandbox = try AppThemeSandbox()
        fake = AppThemeFakeEnvironment()
    }

    override func tearDown() {
        sandbox.remove()
    }

    private func job(_ contents: [String]) -> AppThemeJob {
        AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            appearanceChanged: false,
            targets: [AppThemeTarget(
                id: "transaction",
                name: "Transaction",
                outputs: contents.enumerated().map { index, text in
                    AppThemeOutput(path: "~/.config/transaction/\(index)", template: .text(text))
                },
                reload: nil
            )]
        )
    }

    private func seed(_ contents: [String], pending: Set<Int> = []) throws -> AppThemeState {
        var state = AppThemeState()
        for (index, text) in contents.enumerated() {
            let relative = ".config/transaction/\(index)"
            try sandbox.write(text, to: relative)
            let path = sandbox.path(relative).path
            if pending.contains(index) {
                state.pending[path] = AppThemeFileWriter.digest(text)
            } else {
                state.owned[path] = AppThemeFileWriter.digest(text)
            }
        }
        try sandbox.store.save(state)
        return state
    }

    private func failFinalSave(
        _ engine: inout AppThemeEngine,
        after file: URL,
        changingDuringRestore replacement: String? = nil
    ) {
        let stateURL = sandbox.store.stateURL
        let heldState = sandbox.store.directory.appendingPathComponent("held-state.json")
        engine.willReplace = { url in
            let manager = FileManager.default
            do {
                if manager.fileExists(atPath: heldState.path) {
                    try manager.removeItem(at: stateURL)
                    try manager.moveItem(at: heldState, to: stateURL)
                    if url == file, let replacement {
                        try Data(replacement.utf8).write(to: url)
                    }
                } else if url == file {
                    try manager.moveItem(at: stateURL, to: heldState)
                    try manager.createDirectory(at: stateURL, withIntermediateDirectories: false)
                }
            } catch {
                XCTFail("Could not arrange the state-save failure: \(error)")
            }
        }
    }

    func testFinalStateSaveFailureRestoresTheCurrentAndEarlierOutputs() throws {
        let originals = ["first before\n", "second before\n"]
        let lastIndex = try XCTUnwrap(originals.indices.last)
        let before = try seed(originals, pending: [lastIndex])
        var engine = sandbox.engine(fake)
        let last = sandbox.path(".config/transaction/\(lastIndex)")
        failFinalSave(&engine, after: last)

        let report = engine.run(job(["first after\n", "second after\n"]))

        XCTAssertEqual(report.results["transaction"]?.outcome, .failed)
        for (index, text) in originals.enumerated() {
            XCTAssertEqual(sandbox.read(".config/transaction/\(index)"), text)
        }
        let restored = try sandbox.store.load()
        XCTAssertEqual(restored.owned, before.owned)
        XCTAssertEqual(restored.pending, before.pending)
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testFinalStateSaveFailureRemovesANewCurrentOutput() throws {
        let original = "first before\n"
        let before = try seed([original], pending: [0])
        let replacement = ["first after\n", "new second output\n"]
        let lastIndex = try XCTUnwrap(replacement.indices.last)
        let newFile = sandbox.path(".config/transaction/\(lastIndex)")
        var engine = sandbox.engine(fake)
        failFinalSave(&engine, after: newFile)

        let report = engine.run(job(replacement))

        XCTAssertEqual(report.results["transaction"]?.outcome, .failed)
        XCTAssertEqual(sandbox.read(".config/transaction/0"), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFile.path))
        let restored = try sandbox.store.load()
        XCTAssertEqual(restored.owned, before.owned)
        XCTAssertEqual(restored.pending, before.pending)
    }

    func testFailedRestorationDoesNotRestoreOldOwnership() throws {
        let originals = ["first before\n", "second before\n"]
        let before = try seed(originals)
        let replacement = ["first after\n", "second after\n"]
        let lastIndex = try XCTUnwrap(replacement.indices.last)
        let last = sandbox.path(".config/transaction/\(lastIndex)")
        let external = "edited while rollback began\n"
        var engine = sandbox.engine(fake)
        failFinalSave(&engine, after: last, changingDuringRestore: external)

        let report = engine.run(job(replacement))

        XCTAssertEqual(report.results["transaction"]?.outcome, .failed)
        XCTAssertEqual(sandbox.read(".config/transaction/0"), originals[0])
        XCTAssertEqual(try String(contentsOf: last, encoding: .utf8), external)
        let restored = try sandbox.store.load()
        XCTAssertEqual(restored.owned[last.path], AppThemeFileWriter.digest(replacement[lastIndex]))
        XCTAssertNotEqual(restored.owned[last.path], before.owned[last.path])
        XCTAssertNil(restored.pending[last.path])
    }
}
