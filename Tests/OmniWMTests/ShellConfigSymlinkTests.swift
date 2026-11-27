// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellConfigSymlinkTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let directory: URL
        let target: URL

        var link: URL {
            directory.appendingPathComponent("shell.luau")
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSelectingProfilePreservesAbsoluteShellSymlink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try initialContents.write(to: fixture.target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: fixture.target)

        XCTAssertTrue(try ShellProfiles.select("look", in: fixture.directory))

        try assertSymlink(at: fixture.link, destination: fixture.target.path)
        XCTAssertEqual(try node(["profile"], at: fixture.target), .string("look"))
        XCTAssertEqual(try node(["trailing"], at: fixture.target), .list([.string("clock")]))
        XCTAssertEqual(try Data(contentsOf: fixture.link), try Data(contentsOf: fixture.target))
        XCTAssertFalse(try ShellProfiles.select("look", in: fixture.directory))
    }

    func testProfileEditsFollowRelativeSymlinkChainThroughLinkedDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try initialContents.write(to: fixture.target, atomically: false, encoding: .utf8)
        let destination = try makeRelativeLink(in: fixture)
        let key = ShellProfiles.key("theme", of: "look")

        XCTAssertTrue(try ShellProfiles.select("look", in: fixture.directory))
        XCTAssertTrue(try ShellProfiles.setValue("dusk", at: key, in: fixture.directory))

        try assertSymlink(at: fixture.link, destination: destination)
        try assertSymlink(
            at: fixture.target.deletingLastPathComponent().appendingPathComponent("active.luau"),
            destination: "shell.luau"
        )
        XCTAssertEqual(try node(["profile"], at: fixture.target), .string("look"))
        XCTAssertEqual(try node(key, at: fixture.target), .string("dusk"))
        XCTAssertTrue(try ShellProfiles.setNodes([(key, nil)], in: fixture.directory))
        XCTAssertNil(try node(key, at: fixture.target))
        XCTAssertEqual(try node(["trailing"], at: fixture.target), .list([.string("clock")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("active.luau").path))
    }

    func testIslandEditsPreserveAbsoluteAndRelativeShellSymlinks() async throws {
        for relative in [false, true] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try initialContents.write(to: fixture.target, atomically: false, encoding: .utf8)
            let destination: String
            if relative {
                destination = try makeRelativeLink(in: fixture)
            } else {
                destination = fixture.target.path
                try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: fixture.target)
            }
            let writer = ShellIslandConfigWriter(shellDirectory: fixture.directory, reloadReady: {})
            let components = [ShellComponentInstance(id: "one", widget: "clock")]

            _ = try await writer.persist(.components(components), profile: "look", root: "focus-ribbon")

            try assertSymlink(at: fixture.link, destination: destination)
            let instances = try ShellComponentCatalog.instances(
                in: node(["profiles", "look", "island", "components"], at: fixture.target)
            )
            XCTAssertEqual(instances, components)
            XCTAssertEqual(try node(["profile"], at: fixture.target), .string("default"))
            XCTAssertEqual(try node(["trailing"], at: fixture.target), .list([.string("clock")]))
        }
    }

    func testProfileSelectionRejectsDanglingAndCyclicShellSymlinks() throws {
        for destination in ["../dotfiles/missing.luau", "shell.luau"] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: destination)

            XCTAssertThrowsError(try ShellProfiles.select("look", in: fixture.directory))

            try assertSymlink(at: fixture.link, destination: destination)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path),
                []
            )
        }
    }

    func testIslandEditsRejectDanglingAndCyclicShellSymlinks() async throws {
        for destination in ["../dotfiles/missing.luau", "shell.luau"] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: destination)
            let writer = ShellIslandConfigWriter(shellDirectory: fixture.directory, reloadReady: {})

            do {
                _ = try await writer.persist(.components([]), profile: "look", root: "focus-ribbon")
                XCTFail("Expected the invalid shell symlink to block the write")
            } catch {}

            try assertSymlink(at: fixture.link, destination: destination)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path),
                []
            )
        }
    }

    private var initialContents: String {
        "return { profile = \"default\", trailing = { \"clock\" } }\n"
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("shell", isDirectory: true)
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("look"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        return Fixture(root: root, directory: directory, target: dotfiles.appendingPathComponent("shell.luau"))
    }

    private func makeRelativeLink(in fixture: Fixture) throws -> String {
        let dotfiles = fixture.target.deletingLastPathComponent()
        let nested = dotfiles.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("dotfiles-link"), withDestinationURL: nested
        )
        try FileManager.default.createSymbolicLink(
            atPath: dotfiles.appendingPathComponent("active.luau").path, withDestinationPath: "shell.luau"
        )
        let destination = "../dotfiles-link/../active.luau"
        try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: destination)
        return destination
    }

    private func assertSymlink(
        at url: URL, destination: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: url.path),
            destination,
            file: file,
            line: line
        )
    }

    private func node(_ path: [String], at url: URL) throws -> SettingsLuauValue? {
        let tree = try ShellLuauFixture.table(at: url)
        var node = SettingsLuauValue.record(tree)
        for key in path {
            guard case let .record(table) = node, let next = table[key] else { return nil }
            node = next
        }
        return node
    }
}
