// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellWidgetSourceLoaderTests: XCTestCase {
    func testLayeredComponentsKeepVirtualPathsPhysicalAssetsAndValidatedDisabledOptions() throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        try write("root", shell, "look/widgets/lake/init.luau")
        try write("custom", shell, "widgets/custom/component.luau")
        try write("""
        views = ['compact']
        uses = ['base']
        [options.width]
        type = 'number'
        default = 47
        """, shell, "widgets/custom/component.toml")
        try write("base", shell, "default/widgets/base/component.luau")
        try write("views = ['compact']", shell, "default/widgets/base/component.toml")
        let configured = ShellComponentInstance(id: "personal", widget: "custom", enabled: false)
        let source = try ShellWidgetSourceLoader.build(input(shell, components: [configured]))
        XCTAssertEqual(source.chunk, "@look/widgets/lake/init.luau")
        XCTAssertEqual(source.main, "root")
        XCTAssertEqual(source.profile, "look")
        XCTAssertEqual(source.moduleLimit, 512)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: source.modules.map { ($0.path, $0.source) }), [
            "look/widgets/base/component.luau": "base",
            "look/widgets/custom/component.luau": "custom"
        ])
        XCTAssertEqual(source.componentDescriptors.map(\.widget), ["base", "custom"])
        XCTAssertEqual(source.components.count, 1)
        XCTAssertEqual(source.components.first?.id, "personal")
        XCTAssertEqual(source.components.first?.enabled, false)
        XCTAssertEqual(source.components.first?.options["width"], .number(47))
        XCTAssertEqual(
            source.assetPackages["custom"],
            shell.appendingPathComponent("widgets/custom", isDirectory: true)
        )
        XCTAssertEqual(
            source.assetPackages["base"],
            shell.appendingPathComponent("default/widgets/base", isDirectory: true)
        )
        XCTAssertEqual(
            source.assetPackages["lake"],
            shell.appendingPathComponent("look/widgets/lake", isDirectory: true)
        )
    }

    func testLibraryPrecedenceAndEnumerationKeepOriginalLayerSemantics() throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        try write("root", shell, "look/widgets/lake/init.luau")
        try write("own", shell, "look/widgets/lake/nested/helper.luau")
        try write("user", shell, "lib/lake/policy.luau")
        try write("profile", shell, "look/lib/lake/policy.luau")
        try write("default", shell, "default/lib/lake/policy.luau")
        try write("fallback", shell, "default/lib/lake/view.luau")
        try write("ignored", shell, "look/widgets/lake/.hidden.luau")
        try write("asset", shell, "look/widgets/lake/data.json")
        let captured = input(shell)
        let source = try ShellWidgetSourceLoader.build(captured)
        XCTAssertEqual(source.moduleLimit, 64)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: source.modules.map { ($0.path, $0.source) }), [
            "look/widgets/lake/nested/helper.luau": "own",
            "look/lib/lake/policy.luau": "user",
            "look/lib/lake/view.luau": "fallback"
        ])
        XCTAssertEqual(
            Set(ShellWidgetSourceLoader.packageFiles(captured).map(\.path)),
            Set(source.modules.map(\.path) + ["look/widgets/lake/init.luau"])
        )
        let watched = Set(ShellWidgetSourceLoader.packageDirectories(captured).map(\.standardizedFileURL))
        XCTAssertTrue(watched
            .contains(shell.appendingPathComponent("look/widgets/lake/nested", isDirectory: true).standardizedFileURL))
        XCTAssertTrue(watched.contains(shell.appendingPathComponent("lib", isDirectory: true).standardizedFileURL))
        XCTAssertTrue(watched
            .contains(shell.appendingPathComponent("default/lib/lake", isDirectory: true).standardizedFileURL))
    }

    func testExternalSourceRetainsChunkNameAndDoesNotMountShellModules() throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        let external = shell.deletingLastPathComponent().appendingPathComponent("external.luau")
        try write("external", external.deletingLastPathComponent(), external.lastPathComponent)
        let captured = ShellWidgetSourceLoader.Input(
            name: "custom-name", shellDirectory: shell, sourceURL: external,
            directories: [shell], profile: "look", components: [.init(id: "missing", widget: "missing")]
        )
        let source = try ShellWidgetSourceLoader.build(captured)
        XCTAssertEqual(source.chunk, "=custom-name")
        XCTAssertEqual(source.main, "external")
        XCTAssertEqual(source.profile, "look")
        XCTAssertTrue(source.modules.isEmpty)
        XCTAssertTrue(source.components.isEmpty)
        XCTAssertTrue(source.assetPackages.isEmpty)
        XCTAssertEqual(ShellWidgetSourceLoader.packageFiles(captured).map(\.url), [external])
        XCTAssertTrue(ShellWidgetSourceLoader.packageDirectories(captured).isEmpty)
    }

    func testSourceByteLimitAppliesToMainAndEveryMountedModule() throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        let limit = ShellWidgetSourceLoader.sourceLimit
        try write(String(repeating: "a", count: limit), shell, "look/widgets/lake/init.luau")
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input(shell)).main.utf8.count, limit)
        try write(String(repeating: "a", count: limit + 1), shell, "look/widgets/lake/init.luau")
        XCTAssertThrowsError(try ShellWidgetSourceLoader.build(input(shell))) { error in
            XCTAssertEqual((error as? ShellScriptFailure)?.message, "init.luau is larger than 1 MiB")
        }
        try write("root", shell, "look/widgets/lake/init.luau")
        try write(String(repeating: "b", count: limit + 1), shell, "lib/large.luau")
        XCTAssertThrowsError(try ShellWidgetSourceLoader.build(input(shell))) { error in
            XCTAssertEqual((error as? ShellScriptFailure)?.message, "large.luau is larger than 1 MiB")
        }
    }

    func testModuleCapsIncludeMainAndRejectWithoutTruncation() throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        try write("root", shell, "look/widgets/lake/init.luau")
        for index in 0 ..< 63 { try write("return 1", shell, "lib/\(index).luau") }
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input(shell)).modules.count, 63)
        try write("return 1", shell, "lib/63.luau")
        XCTAssertThrowsError(try ShellWidgetSourceLoader.build(input(shell))) { error in
            XCTAssertEqual((error as? ShellScriptFailure)?.message, "lake has 65 Luau files; the limit is 64")
        }
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input(shell, components: [])).modules.count, 64)
        for index in 64 ..< 511 { try write("return 1", shell, "lib/\(index).luau") }
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input(shell, components: [])).modules.count, 511)
        try write("return 1", shell, "lib/511.luau")
        XCTAssertThrowsError(try ShellWidgetSourceLoader.build(input(shell, components: []))) { error in
            XCTAssertEqual((error as? ShellScriptFailure)?.message, "lake has 513 Luau files; the limit is 512")
        }
    }

    func testMissingAndCyclicDependenciesFailBeforeReturningSource() throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        try write("root", shell, "look/widgets/lake/init.luau")
        try write("a", shell, "widgets/a/component.luau")
        try write("views = ['compact']\nuses = ['b']", shell, "widgets/a/component.toml")
        let captured = input(shell, components: [.init(id: "a", widget: "a")])
        XCTAssertThrowsError(try ShellWidgetSourceLoader.build(captured)) { error in
            XCTAssertEqual((error as? ShellComponentCatalog.Failure)?.message, "No component named b is installed")
        }
        try write("b", shell, "widgets/b/component.luau")
        try write("views = ['compact']\nuses = ['a']", shell, "widgets/b/component.toml")
        XCTAssertThrowsError(try ShellWidgetSourceLoader.build(captured)) { error in
            XCTAssertEqual((error as? ShellComponentCatalog.Failure)?.message, "Component dependency cycle at a")
        }
    }

    func testUtilityPreparationUsesCapturedInputAndReadsFreshFilesWithoutACache() async throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        try write("first", shell, "look/widgets/lake/init.luau")
        try write("module-one", shell, "lib/shared.luau")
        let captured = input(shell, components: [])
        let loader = ShellWidgetSourceLoader()
        let firstPrepared = try await loader.prepare(captured)
        let first = firstPrepared.source
        XCTAssertEqual(first.main, "first")
        XCTAssertEqual(first.modules.first?.source, "module-one")
        XCTAssertEqual(first.moduleLimit, 512)
        try write("second", shell, "look/widgets/lake/init.luau")
        try write("module-two", shell, "lib/shared.luau")
        let secondPrepared = try await loader.prepare(captured)
        let second = secondPrepared.source
        XCTAssertNotEqual(firstPrepared.fingerprint, secondPrepared.fingerprint)
        XCTAssertEqual(secondPrepared.fingerprint, ShellWidgetSourceLoader.fingerprint(captured))
        XCTAssertEqual(second.main, "second")
        XCTAssertEqual(second.modules.first?.source, "module-two")
        XCTAssertEqual(first.main, "first")
        XCTAssertEqual(first.modules.first?.source, "module-one")
        XCTAssertEqual(second.profile, "look")
    }

    func testPreparedFingerprintIncludesTransitiveAndOverriddenManifestPaths() async throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        try write("root", shell, "look/widgets/lake/init.luau")
        try write("a", shell, "widgets/a/component.luau")
        try write("views = ['compact']\nuses = ['base']", shell, "widgets/a/component.toml")
        try write("views = ['compact']", shell, "look/widgets/a/component.toml")
        try write("base", shell, "default/widgets/base/component.luau")
        try write("views = ['compact']", shell, "default/widgets/base/component.toml")
        let captured = input(shell, components: [.init(id: "a", widget: "a")])
        let prepared = try await ShellWidgetSourceLoader().prepare(captured)
        XCTAssertEqual(Set(prepared.fingerprint.keys), [
            "look/widgets/lake/init.luau", "look/widgets/a/component.luau", "look/widgets/base/component.luau",
            shell.appendingPathComponent("widgets/a/component.toml").path,
            shell.appendingPathComponent("look/widgets/a/component.toml").path,
            shell.appendingPathComponent("default/widgets/base/component.toml").path
        ])
        XCTAssertEqual(
            prepared.fingerprint,
            ShellWidgetSourceLoader.fingerprint(captured, components: prepared.source.componentDescriptors)
        )
    }

    func testRootNetworkComesOnlyFromTheSettingsBesideTheEffectiveSource() throws {
        let shell = temporaryShell()
        defer { try? FileManager.default.removeItem(at: shell.deletingLastPathComponent()) }
        try write("root", shell, "look/widgets/lake/init.luau")
        try write("capabilities = { network = [\"inherited.example\"] }", shell, "default/widgets/lake/settings.toml")
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input(shell)).network, [])
        try write("capabilities = { network = [\"API.example\"] }", shell, "look/widgets/lake/settings.toml")
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input(shell)).network, ["API.example"])
        let settings = shell.appendingPathComponent("look/widgets/lake/settings.toml").path
        XCTAssertNotNil(ShellWidgetSourceLoader.fingerprint(input(shell))[settings])
        try write(
            "capabilities = { network = [\"api.example\"], files = true }",
            shell,
            "look/widgets/lake/settings.toml"
        )
        XCTAssertThrowsError(try ShellRootSettings.load("lake", directories: [shell.appendingPathComponent("look")]))
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input(shell)).network, [])
    }

    private func temporaryShell() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("shell")
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
