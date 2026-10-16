// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellProviderLifecycleTests: XCTestCase {
    func testReplacementWaitsForActualTerminationAndFinalDrain() throws {
        var lifecycle = ShellProviderLifecycle(owner: owner)
        let first = config(1)
        let next = config(2)
        let start = lifecycle.reconcile(first)
        let identity = try XCTUnwrap(lifecycle.identity)
        XCTAssertEqual(start, [.launch(identity, first)])
        XCTAssertTrue(lifecycle.acceptsActions)
        XCTAssertEqual(lifecycle.launched(identity), [.running(identity)])
        XCTAssertEqual(lifecycle.reconcile(next), [.closeInput(identity)])
        XCTAssertEqual(lifecycle.phase, .closingInput)
        XCTAssertTrue(lifecycle.killDeadline(identity).isEmpty)
        XCTAssertEqual(lifecycle.inputClosed(identity), [.terminate(identity), .armKill(identity)])
        XCTAssertTrue(lifecycle.inputClosed(identity).isEmpty)
        XCTAssertFalse(lifecycle.acceptsActions)
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertTrue(lifecycle.drained(identity).isEmpty)
        XCTAssertEqual(lifecycle.killDeadline(identity), [.kill(identity)])
        XCTAssertEqual(lifecycle.exited(identity, code: 15), [.closeInput(identity), .cancelKill(identity)])
        XCTAssertEqual(lifecycle.phase, .draining)
        XCTAssertTrue(lifecycle.killDeadline(identity).isEmpty)
        let replacement = ShellProviderIdentity(owner: owner, incarnation: identity.incarnation + 1)
        XCTAssertEqual(lifecycle.drained(identity), [.ended(identity, .exited(15)), .launch(replacement, next)])
        XCTAssertEqual(lifecycle.identity, replacement)
        XCTAssertTrue(lifecycle.exited(identity, code: 0).isEmpty)
        XCTAssertTrue(lifecycle.killDeadline(identity).isEmpty)
    }

    func testOnlyLatestReplacementSurvivesAndDisableCancelsIt() throws {
        var lifecycle = ShellProviderLifecycle(owner: owner)
        _ = lifecycle.reconcile(config(1))
        let identity = try XCTUnwrap(lifecycle.identity)
        _ = lifecycle.launched(identity)
        _ = lifecycle.reconcile(config(2))
        XCTAssertTrue(lifecycle.reconcile(config(3)).isEmpty)
        _ = lifecycle.exited(identity, code: 0)
        let next = ShellProviderIdentity(owner: owner, incarnation: 2)
        XCTAssertEqual(lifecycle.drained(identity), [.ended(identity, .exited(0)), .launch(next, config(3))])
        _ = lifecycle.launched(next)
        _ = lifecycle.reconcile(config(4))
        XCTAssertTrue(lifecycle.reconcile(nil).isEmpty)
        _ = lifecycle.exited(next, code: 0)
        XCTAssertEqual(lifecycle.drained(next), [.ended(next, .exited(0))])
        XCTAssertEqual(lifecycle.phase, .terminal)
        let reenabled = ShellProviderIdentity(owner: owner, incarnation: 3)
        XCTAssertEqual(lifecycle.reconcile(config(3)), [.launch(reenabled, config(3))])
    }

    func testCrashAndLaunchFailureDoNotAutomaticallyRestart() throws {
        var lifecycle = ShellProviderLifecycle(owner: owner)
        let configuration = config(1)
        _ = lifecycle.reconcile(configuration)
        let identity = try XCTUnwrap(lifecycle.identity)
        _ = lifecycle.launched(identity)
        _ = lifecycle.exited(identity, code: 9)
        XCTAssertEqual(lifecycle.drained(identity), [.ended(identity, .exited(9))])
        XCTAssertTrue(lifecycle.reconcile(configuration).isEmpty)
        XCTAssertTrue(lifecycle.exited(identity, code: 9).isEmpty)
        _ = lifecycle.reconcile(nil)
        let second = lifecycle.reconcile(configuration)
        let next = try XCTUnwrap(lifecycle.identity)
        XCTAssertEqual(second, [.launch(next, configuration)])
        XCTAssertEqual(
            lifecycle.launchFailed(next, message: "not executable"),
            [.ended(next, .failed("not executable"))]
        )
        XCTAssertTrue(lifecycle.reconcile(configuration).isEmpty)
        XCTAssertFalse(lifecycle.acceptsActions)
    }

    func testProtocolFailureEndsIngressAndCloseWaitsWithoutLaunchingReplacement() throws {
        var lifecycle = ShellProviderLifecycle(owner: owner)
        _ = lifecycle.reconcile(config(1))
        let identity = try XCTUnwrap(lifecycle.identity)
        _ = lifecycle.launched(identity)
        XCTAssertEqual(lifecycle.failed(identity, message: "invalid line"), [
            .ended(identity, .failed("invalid line")), .closeInput(identity)
        ])
        XCTAssertFalse(lifecycle.acceptsActions)
        _ = lifecycle.reconcile(config(2))
        XCTAssertTrue(lifecycle.close().isEmpty)
        XCTAssertFalse(lifecycle.isClosed)
        _ = lifecycle.exited(identity, code: 9)
        XCTAssertEqual(lifecycle.drained(identity), [.ended(identity, .failed("invalid line"))])
        XCTAssertTrue(lifecycle.isClosed)
        XCTAssertTrue(lifecycle.reconcile(config(3)).isEmpty)
    }

    func testEarlyStdoutEOFTerminatesButWaitsForExitStatus() throws {
        var lifecycle = ShellProviderLifecycle(owner: owner)
        _ = lifecycle.reconcile(config(1))
        let identity = try XCTUnwrap(lifecycle.identity)
        _ = lifecycle.launched(identity)
        XCTAssertEqual(lifecycle.outputClosed(identity), [.closeInput(identity)])
        XCTAssertEqual(lifecycle.phase, .closingInput)
        _ = lifecycle.exited(identity, code: 0)
        XCTAssertTrue(lifecycle.inputClosed(identity).isEmpty)
        XCTAssertEqual(lifecycle.drained(identity), [.ended(identity, .exited(0))])
    }

    private var owner: ShellServiceOwner {
        .init(generation: 1, owner: 2, epoch: 3)
    }

    private func config(_ option: Int) -> ShellProviderConfiguration {
        ShellProviderConfiguration(
            widget: "converter", instance: "one", folder: URL(fileURLWithPath: "/tmp/provider-fixture"),
            command: ["bin/convert"], options: Data("{\"value\":\(option)}".utf8), authorized: true
        )
    }
}
