// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppThemingPageStateTests: XCTestCase {
    private var sandbox: AppThemeSandbox!

    override func setUpWithError() throws {
        sandbox = try AppThemeSandbox()
    }

    override func tearDown() {
        sandbox.remove()
    }

    private var allTargets: [AppThemeTarget] {
        var values = SettingsExport.AppTheming()
        for app in AppThemeBuiltIn.allCases { values.setEnabled(app, true) }
        return values.targets(configHome: sandbox.policy.configHome)
    }

    @MainActor
    func testPathsAndGhosttyStatusAreWorkedOutOnTheWorker() throws {
        try sandbox.write("theme = catppuccin\n", to: ".config/ghostty/config")
        let worker = AppThemeHeldWork()
        let hops = AppThemeHeldHops()
        let state = AppThemingPageState(perform: worker.perform, deliver: hops.deliver)
        state.refresh(sandbox.engine(AppThemeFakeEnvironment()), targets: allTargets)
        XCTAssertTrue(state.paths.isEmpty)
        XCTAssertEqual(worker.count, 1)
        worker.release()
        XCTAssertTrue(state.paths.isEmpty)
        hops.release()
        XCTAssertEqual(
            state.paths["kitty"],
            ["~/.config/kitty/light-theme.auto.conf", "~/.config/kitty/dark-theme.auto.conf"]
        )
        XCTAssertEqual(state.paths["herdr"], ["~/.config/herdr/config.toml"])
        XCTAssertEqual(state.ghosttyStatus, .notSelected)
        XCTAssertEqual(state.backupFolder, "~/.local/state/omniwm/app-theming/backups")
    }

    @MainActor
    func testAnOlderRefreshNeverReplacesANewerOne() throws {
        let worker = AppThemeHeldWork()
        let hops = AppThemeHeldHops()
        let state = AppThemingPageState(perform: worker.perform, deliver: hops.deliver)
        let engine = sandbox.engine(AppThemeFakeEnvironment())
        state.refresh(engine, targets: allTargets)
        state.refresh(engine, targets: [])
        worker.releaseNewest()
        worker.release()
        XCTAssertEqual(hops.count, 2)
        hops.release()
        XCTAssertTrue(state.paths.isEmpty)
        XCTAssertEqual(state.backupFolder, "~/.local/state/omniwm/app-theming/backups")
    }

    @MainActor
    func testReviewReadsFilesOnTheWorkerAndDeliversTheCapturedBytes() throws {
        let worker = AppThemeHeldWork()
        let hops = AppThemeHeldHops()
        let state = AppThemingPageState(perform: worker.perform, deliver: hops.deliver)
        let preview = AppThemePreview(
            engine: sandbox.engine(AppThemeFakeEnvironment()), values: .init(), dark: false
        ) { AppThemeFixtures.palette }
        let file = ".config/herdr/config.toml"
        let before = "[keys]\nprefix = \"x\"\n"
        var received: Result<[AppThemeChange], Error>?
        state.review(preview, target: preview.target(for: .herdr)) { received = $0 }
        XCTAssertNil(received)
        try sandbox.write(before, to: file)
        worker.release()
        XCTAssertNil(received)
        try sandbox.write("[keys]\nprefix = \"y\"\n", to: file)
        hops.release()
        let changes = try XCTUnwrap(received).get()
        let change = try XCTUnwrap(changes.first)
        XCTAssertEqual(change.before, before)
        XCTAssertEqual(change.beforeDigest, AppThemeFileWriter.digest(Data(before.utf8)))
    }

    @MainActor
    func testNewerReviewAndInvalidationDiscardOldCompletions() {
        let worker = AppThemeHeldWork()
        let hops = AppThemeHeldHops()
        let state = AppThemingPageState(perform: worker.perform, deliver: hops.deliver)
        let preview = AppThemePreview(
            engine: sandbox.engine(AppThemeFakeEnvironment()), values: .init(), dark: false
        ) { AppThemeFixtures.palette }
        var delivered: [String] = []
        state.review(preview) { _ in delivered.append("old") }
        state.review(preview) { _ in delivered.append("current") }
        worker.releaseNewest()
        worker.release()
        hops.release()
        XCTAssertEqual(delivered, ["current"])
        state.review(preview) { _ in delivered.append("invalidated") }
        worker.release()
        state.invalidateReview()
        hops.release()
        XCTAssertEqual(delivered, ["current"])
    }

    @MainActor
    func testInvalidCustomTemplateReportsItsErrorOnDelivery() throws {
        let worker = AppThemeHeldWork()
        let hops = AppThemeHeldHops()
        let state = AppThemingPageState(perform: worker.perform, deliver: hops.deliver)
        let preview = AppThemePreview(
            engine: sandbox.engine(AppThemeFakeEnvironment()), values: .init(), dark: false
        ) { AppThemeFixtures.palette }
        let custom = SettingsExport.AppTheming.Custom(
            name: "Missing template", template: sandbox.path("missing.template").path,
            output: sandbox.path(".config/custom/theme").path
        )
        var received: Result<[AppThemeChange], Error>?
        state.review(preview, target: preview.target(for: custom)) { received = $0 }
        worker.release()
        XCTAssertNil(received)
        hops.release()
        XCTAssertThrowsError(try XCTUnwrap(received).get())
    }
}
