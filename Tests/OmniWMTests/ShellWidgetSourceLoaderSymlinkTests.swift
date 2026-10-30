// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellWidgetSourceLoaderSymlinkTests: XCTestCase {
    func testLinkedLibrariesKeepLayerPrecedenceAndLogicalPathsForWidgetsAndRoots() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("root", root, "shell/look/widgets/lake/init.luau")
        try write("user", root, "shell/lib/lake/policy.luau")
        try write("profile", root, "shell/look/lib/lake/policy.luau")
        try write("profile-only", root, "shell/look/lib/lake/profile.luau")
        try write("default", root, "shell/default/lib/lake/policy.luau")
        try write("default-only", root, "shell/default/lib/lake/view.luau")
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        for layer in ["lib", "look/lib", "default/lib"] {
            let library = shell.appendingPathComponent(layer, isDirectory: true)
            let target = root.appendingPathComponent("targets/" + layer, isDirectory: true)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: library, to: target)
            try FileManager.default.createSymbolicLink(at: library, withDestinationURL: target)
            for isRoot in [false, true] {
                let captured = input(shell, components: isRoot ? [] : nil)
                let source = try ShellWidgetSourceLoader.build(captured)
                XCTAssertEqual(source.chunk, "@look/widgets/lake/init.luau")
                XCTAssertEqual(source.isIslandRoot, isRoot)
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: source.modules.map { ($0.path, $0.source) }), [
                    "look/lib/lake/policy.luau": "user",
                    "look/lib/lake/profile.luau": "profile-only",
                    "look/lib/lake/view.luau": "default-only"
                ])
                XCTAssertEqual(captured.libraries, ["lib", "look/lib", "default/lib"].map {
                    shell.appendingPathComponent($0, isDirectory: true)
                })
                let files = Dictionary(uniqueKeysWithValues: ShellWidgetSourceLoader.packageFiles(captured).map {
                    ($0.path, $0.url)
                })
                XCTAssertEqual(files["look/lib/lake/policy.luau"], shell.appendingPathComponent("lib/lake/policy.luau"))
                XCTAssertEqual(
                    files["look/lib/lake/profile.luau"],
                    shell.appendingPathComponent("look/lib/lake/profile.luau")
                )
                XCTAssertEqual(
                    files["look/lib/lake/view.luau"],
                    shell.appendingPathComponent("default/lib/lake/view.luau")
                )
                let watched = Set(ShellWidgetSourceLoader.packageDirectories(captured))
                for directory in ["lib", "lib/lake", "look/lib", "look/lib/lake", "default/lib", "default/lib/lake"] {
                    XCTAssertTrue(
                        watched.contains(shell.appendingPathComponent(directory, isDirectory: true)),
                        directory
                    )
                }
            }
        }
    }

    func testLinkedLibraryPreparationTracksEditsAtomicReplacementAndRetargeting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("root", root, "shell/look/widgets/lake/init.luau")
        try write("fallback", root, "shell/default/lib/policy.luau")
        try write("first", root, "first/policy.luau")
        try write("second", root, "second/policy.luau")
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let link = shell.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../first")
        let captured = input(shell)
        let loader = ShellWidgetSourceLoader()
        let key = "look/lib/policy.luau"
        var prepared = try await loader.prepare(captured)
        XCTAssertEqual(prepared.source.modules.first { $0.path == key }?.source, "first")
        XCTAssertEqual(
            prepared.fingerprint[key],
            SettingsFileAccess.currentFingerprint(at: root.appendingPathComponent("first/policy.luau"))
        )
        for atomic in [false, true] {
            let text = atomic ? "atomic replacement" : "edited in place"
            try Data(text.utf8).write(
                to: root.appendingPathComponent("first/policy.luau"),
                options: atomic ? .atomic : []
            )
            let updated = try await loader.prepare(captured)
            XCTAssertEqual(updated.source.modules.first { $0.path == key }?.source, text)
            XCTAssertNotEqual(updated.fingerprint, prepared.fingerprint)
            prepared = updated
        }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../second")
        let retargeted = try await loader.prepare(captured)
        XCTAssertEqual(retargeted.source.modules.first { $0.path == key }?.source, "second")
        XCTAssertNotEqual(retargeted.fingerprint, prepared.fingerprint)
        XCTAssertEqual(
            retargeted.fingerprint[key],
            SettingsFileAccess.currentFingerprint(at: root.appendingPathComponent("second/policy.luau"))
        )
        XCTAssertEqual(captured.libraries.first, link)
        XCTAssertEqual(prepared.source.modules.first { $0.path == key }?.source, "atomic replacement")
    }

    func testLinkedLibraryFingerprintTracksAddedAndRemovedModules() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("root", root, "shell/look/widgets/lake/init.luau")
        try write("first", root, "target/nested/first.luau")
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let link = shell.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../alias")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("alias").path,
            withDestinationPath: "target"
        )
        let captured = input(shell)
        let original = ShellWidgetSourceLoader.fingerprint(captured)
        XCTAssertNotNil(original["look/lib/nested/first.luau"])
        try write("added", root, "target/nested/added.luau")
        let added = ShellWidgetSourceLoader.fingerprint(captured)
        XCTAssertNotEqual(added, original)
        XCTAssertNotNil(added["look/lib/nested/added.luau"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("target/nested/first.luau"))
        let removed = ShellWidgetSourceLoader.fingerprint(captured)
        XCTAssertNotEqual(removed, added)
        XCTAssertNil(removed["look/lib/nested/first.luau"])
        XCTAssertEqual(try ShellWidgetSourceLoader.build(captured).modules.map(\.path), ["look/lib/nested/added.luau"])
    }

    func testInvalidLibraryLinksFallBackAndDanglingLinksRecoverWithCapturedInput() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("root", root, "shell/look/widgets/lake/init.luau")
        try write("fallback", root, "shell/default/lib/policy.luau")
        try write("not a directory", root, "file")
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let link = shell.appendingPathComponent("lib", isDirectory: true)
        let captured = input(shell)
        let fallback = ShellWidgetSourceLoader.fingerprint(captured)
        for destination in ["../missing", "../file", "lib"] {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            XCTAssertEqual(captured.libraries, [shell.appendingPathComponent("default/lib", isDirectory: true)])
            XCTAssertEqual(try ShellWidgetSourceLoader.build(captured).modules.first?.source, "fallback")
            XCTAssertEqual(ShellWidgetSourceLoader.fingerprint(captured), fallback)
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../missing")
        try write("recovered", root, "missing/policy.luau")
        XCTAssertEqual(captured.libraries.first, link)
        XCTAssertEqual(try ShellWidgetSourceLoader.build(captured).modules.first?.source, "recovered")
        XCTAssertNotEqual(ShellWidgetSourceLoader.fingerprint(captured), fallback)
    }

    func testUnavailableLibraryPathsRemainWatchedWhileLoadingFallsBack() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("root", root, "shell/look/widgets/lake/init.luau")
        try write("fallback", root, "shell/default/lib/policy.luau")
        try write("not a directory", root, "file")
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let link = shell.appendingPathComponent("lib", isDirectory: true)
        let captured = input(shell)
        let fallback = ShellWidgetSourceLoader.fingerprint(captured)
        for destination in ["../missing", "../file", "lib"] {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            XCTAssertEqual(captured.libraries, [shell.appendingPathComponent("default/lib", isDirectory: true)])
            XCTAssertEqual(try ShellWidgetSourceLoader.build(captured).modules.first?.source, "fallback")
            XCTAssertEqual(ShellWidgetSourceLoader.fingerprint(captured), fallback)
            let watched = Set(ShellWidgetSourceLoader.packageDirectories(captured))
            for library in ["lib", "look/lib", "default/lib"] {
                XCTAssertTrue(watched.contains(shell.appendingPathComponent(library, isDirectory: true)), library)
            }
            try FileManager.default.removeItem(at: link)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func input(_ shell: URL, components: [ShellComponentInstance]? = nil) -> ShellWidgetSourceLoader.Input {
        ShellWidgetSourceLoader.Input(
            name: "lake", shellDirectory: shell, sourceURL: shell.appendingPathComponent("look/widgets/lake/init.luau"),
            directories: [shell, shell.appendingPathComponent("look"), shell.appendingPathComponent("default")],
            profile: "look", components: components
        )
    }

    private func write(_ text: String, _ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
