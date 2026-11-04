// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

@MainActor
final class HostedAppCommandTests: XCTestCase {
    func testTheExamplePaletteActionUsesTheSameCommandAsCLIAndIPC() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: ActionCatalog.shellAppExampleActionID))
        let appID = ShellAppWindowManager.exampleID
        let command = HotkeyCommand.shellAppOpen(appID)
        let descriptor = try XCTUnwrap(spec.ipcDescriptor)
        let words = descriptor.commandWords + [appID]
        let request = try XCTUnwrap(IPCCommandRequest(commandWords: words))

        XCTAssertEqual(spec.command, command)
        XCTAssertEqual(spec.title, "Open OmniShell Example")
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertTrue(ActionCatalog.allSpecs().contains(spec))
        XCTAssertEqual(request, .shellAppOpen(appID: appID))
        let cli = try CLIParser.parse(arguments: ["omniwmctl", "command"] + words)
        XCTAssertEqual(cli.request.payload, .command(request))
        XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: JSONEncoder().encode(request)), request)
    }

    func testHostedAppCommandsRequireOneNonemptyAppIdentifier() throws {
        for name in [IPCCommandName.shellAppOpen, .shellAppNewWindow] {
            let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: name))
            XCTAssertNil(IPCCommandRequest(commandWords: descriptor.commandWords))
            XCTAssertNil(IPCCommandRequest(commandWords: descriptor.commandWords + [""]))
            XCTAssertNil(IPCCommandRequest(commandWords: descriptor.commandWords + ["example", "extra"]))
            XCTAssertThrowsError(try IPCCommandRequest(name: name))
            XCTAssertThrowsError(try IPCCommandRequest(name: name, argumentValues: [.appID("")]))
            let json = #"{"name":"\#(name.rawValue)","arguments":{"appId":""}}"#
            XCTAssertThrowsError(try JSONDecoder().decode(IPCCommandRequest.self, from: Data(json.utf8)))
        }
    }

    func testNewWindowPaletteActionUsesTheSameCommandAsCLIAndIPC() throws {
        let appID = "example"
        let spec = try XCTUnwrap(ActionCatalog.spec(for: ActionCatalog.shellAppNewWindowExampleActionID))
        let descriptor = try XCTUnwrap(spec.ipcDescriptor)
        let words = ["app-new-window", appID]
        let request = try XCTUnwrap(IPCCommandRequest(commandWords: words))

        XCTAssertEqual(spec.command, .shellAppNewWindow(appID))
        XCTAssertEqual(spec.title, "New OmniShell Example Window")
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertTrue(ActionCatalog.allSpecs().contains(spec))
        XCTAssertEqual(descriptor.commandWords, ["app-new-window"])
        XCTAssertEqual(request, .shellAppNewWindow(appID: appID))
        let cli = try CLIParser.parse(arguments: ["omniwmctl", "command"] + words)
        XCTAssertEqual(cli.request.payload, .command(request))
        XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: JSONEncoder().encode(request)), request)
    }

    func testMissingExampleResourceReturnsNotFoundWithoutCreatingAWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("MissingExample.bundle/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.missing-example.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        XCTAssertNil(ShellAppDefinition.example(in: bundle))
        let controller = WindowAdmissionTestSupport.controller(prefix: "MissingHostedExample")
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let manager = controller.shellAppWindowManager
        let sequence = controller.workspaceManager.worldSeq
        manager.makeWindow = { _ in
            XCTFail("A missing bundled component cannot create a native window")
            return NSWindow()
        }

        XCTAssertFalse(manager.open(ShellAppWindowManager.exampleID, bundle: bundle))
        XCTAssertFalse(manager.newWindow(ShellAppWindowManager.exampleID, bundle: bundle))

        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertTrue(manager.runtimes.isEmpty)
        XCTAssertEqual(controller.workspaceManager.worldSeq, sequence)
    }

    func testUnknownAppCommandsReturnNotFoundThroughHotkeyAndIPCRoutes() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "UnknownHostedApp")
        defer {
            controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let appID = "missing-hosted-app"
        let manager = controller.shellAppWindowManager
        let sequence = controller.workspaceManager.worldSeq
        let router = IPCCommandRouter(controller: controller, sessionToken: "hosted-app-command-test")
        manager.makeWindow = { _ in
            XCTFail("An unknown app cannot create a native window")
            return NSWindow()
        }

        XCTAssertEqual(controller.commandHandler.performCommand(.shellAppOpen(appID)), .notFound)
        XCTAssertEqual(controller.commandHandler.performCommand(.shellAppNewWindow(appID)), .notFound)
        XCTAssertEqual(router.handle(.shellAppOpen(appID: appID)), .notFound)
        XCTAssertEqual(router.handle(.shellAppNewWindow(appID: appID)), .notFound)
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertTrue(manager.runtimes.isEmpty)
        XCTAssertEqual(controller.workspaceManager.worldSeq, sequence)
    }

    func testEachRendererViewUsesItsStableTraceName() {
        XCTAssertEqual(ShellWidgetView.allCases.map(\.traceLabel), ["bar", "popout", "window"])
    }
}
