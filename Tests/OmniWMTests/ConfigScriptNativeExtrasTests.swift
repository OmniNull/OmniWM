// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptNativeExtrasTests: XCTestCase {
    func testMatchedNativeExtrasRunWithoutEnteringLua() async throws {
        let controller = InputControllerTestSupport.controller(for: self)
        controller.settings.workspaceBar.enabled = false
        let screenBounds = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        controller.currentMouseLocation = {
            CGPoint(x: screenBounds.maxX + screenBounds.width, y: screenBounds.minY - screenBounds.height)
        }
        let bundle = "org.omniwm.tests.missing.\(UUID().uuidString)"
        let program = "/usr/bin/true"
        let message = "Native notice"
        let declarations: [(String, HotkeyCommand)] = [
            ("omniwm.act.open('\(bundle)')", .openApp(bundle)),
            ("omniwm.act.run({'\(program)'})", .runProgram([program])),
            ("omniwm.act.notify('\(message)')", .showNotice(message))
        ]
        let source = zip(["O", "R", "N"], declarations).map { key, declaration in
            "omniwm.keymap.set('Left Option+\(key)', \(declaration.0))"
        }.joined(separator: "\n")
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        XCTAssertNil(result.generation)
        XCTAssertEqual(result.bindings.map(\.command), declarations.map(\.1))
        let center = controller.hotkeys
        center.sideSpecificDispatch = result.bindings.map {
            CommandHotkeyTapMatcher.Entry(binding: $0.chord, command: $0.command)
        }
        let before = omni_config_vm_entry_count()
        for row in result.bindings {
            let flags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
            XCTAssertTrue(center.dispatchCommandKeyDown(keyCode: row.chord.keyCode, rawFlags: flags))
            XCTAssertEqual(omni_config_vm_entry_count(), before)
        }
        let notice = controller.commandHandler.scriptNotice
        XCTAssertEqual(notice.text, message)
        let timer = try XCTUnwrap(notice.dismissalTimer)
        timer.fireDate = .distantFuture
        let replacement = "Replacement notice"
        let earliest = Date(timeIntervalSinceNow: ShellTooltip.noticeDuration)
        XCTAssertEqual(controller.commandHandler.performCommand(.showNotice(replacement)), .executed)
        let latest = Date(timeIntervalSinceNow: ShellTooltip.noticeDuration)
        XCTAssertTrue(timer === notice.dismissalTimer)
        XCTAssertTrue((earliest ... latest).contains(timer.fireDate))
        XCTAssertEqual(notice.text, replacement)
        timer.fire()
        XCTAssertNil(notice.text)
        XCTAssertNil(notice.dismissalTimer)
        print(
            "Config native open/run/notify matched presses=\(result.bindings.count), VM entries=\(omni_config_vm_entry_count() - before)"
        )
    }

    func testBareExecutableUsesAppPathAndPreservesLiteralArguments() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let program = "move-test-file"
        try files.createSymbolicLink(
            at: root.appendingPathComponent(program), withDestinationURL: URL(fileURLWithPath: "/bin/mv")
        )
        let from = root.appendingPathComponent("source")
        let to = root.appendingPathComponent("literal $(unexpanded) '雪'")
        let value = Data(to.lastPathComponent.utf8)
        try value.write(to: from)
        let descriptor = open(from.path, O_EVTONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let changes = boundedChanges()
        let rename = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .rename,
            queue: .main
        )
        rename.setEventHandler { changes.changed.yield() }
        rename.setCancelHandler { close(descriptor) }
        rename.resume()
        defer { rename.cancel() }
        try await LauncherProcess.start([program, from.path, to.path], environment: ["PATH": root.path])
        await changes.changes.wait { files.fileExists(atPath: to.path) }
        XCTAssertEqual(try Data(contentsOf: to), value)
        do {
            try await LauncherProcess.start([program], environment: [:])
            XCTFail("A bare name needs OmniWM's PATH")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(program))
        }
    }

    func testStartAcknowledgesSpawnWhileTheChildIsWaitingForInput() async throws {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        defer { try? FileManager.default.removeItem(at: fifo) }
        let started = expectation(description: "Spawn acknowledged")
        let task = Task {
            defer { started.fulfill() }
            try await LauncherProcess.start(["/bin/cat", fifo.path])
        }
        guard await XCTWaiter.fulfillment(of: [started], timeout: failureBound) == .completed else {
            try? FileHandle(forUpdating: fifo).close()
            return XCTFail("Starting a command waited for its child to exit")
        }
        try await task.value
        try FileHandle(forWritingTo: fifo).close()
    }
}
