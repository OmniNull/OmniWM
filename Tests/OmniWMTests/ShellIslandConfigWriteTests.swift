// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import TOML
import XCTest

@MainActor
final class ShellIslandConfigWriteTests: XCTestCase {
    func testAddCopiesEffectiveListAndMovePreservesIdentityAndPrivileges() throws {
        let source = ShellIslandLayout(profile: "lake", root: "lake", components: [
            ShellComponentInstance(
                id: "london",
                widget: "clock",
                provider: true,
                options: ["zone": .string("Europe/London")],
                capabilities: ShellComponentCapabilities(commands: ["open"], files: true)
            ),
            ShellComponentInstance(
                id: "tokyo",
                widget: "clock",
                enabled: false,
                options: ["zone": .string("Asia/Tokyo")]
            )
        ])
        let added = try source.applying(
            .add(widget: "clock", options: ["zone": .string("America/Toronto")]),
            catalog: ["clock": descriptor()],
            makeID: { "toronto" }
        )
        XCTAssertEqual(added.instanceID, "toronto")
        XCTAssertFalse(added.layout.components[2].provider)
        XCTAssertNil(added.layout.components[2].capabilities)
        let moved = try added.layout.applying(.move(id: "toronto", index: 1), catalog: [:])
        XCTAssertEqual(moved.layout.components.map(\.id), ["toronto", "london", "tokyo"])
        XCTAssertEqual(moved.layout.components[1], source.components[0])
        let original = "profile = 'lake'\n[profiles.lake.widgets.clock]\nformat = 'HH:mm'\n"
        let persisted = try ShellIslandLayout.persisted(moved.change, profile: "lake", root: "lake", in: original)
        let tree = try parsed(persisted)
        XCTAssertEqual(try instances(tree).map(\.id), ["toronto", "london", "tokyo"])
        XCTAssertEqual(try instances(tree)[1], source.components[0])
        XCTAssertEqual(node(["profiles", "lake", "widgets", "clock", "format"], in: tree), .string("HH:mm"))
        XCTAssertEqual(node(["profile"], in: tree), .string("lake"))
    }

    func testInvalidAddMoveAndPrivilegeOptionsAreRejected() throws {
        let source = ShellIslandLayout(
            profile: "lake",
            root: "lake",
            components: [ShellComponentInstance(id: "one", widget: "clock")]
        )
        let catalog = ["clock": descriptor()]
        for key in ShellComponentCatalog.reservedOptions {
            XCTAssertThrowsError(try source.applying(
                .add(widget: "clock", options: [key: .bool(true)]),
                catalog: catalog
            ))
            XCTAssertThrowsError(try source.applying(.set(id: "one", key: key, value: .bool(true)), catalog: catalog))
        }
        XCTAssertThrowsError(try source.applying(.add(widget: "missing", options: [:]), catalog: catalog))
        XCTAssertThrowsError(try source.applying(
            .add(widget: "clock", options: ["zone": .number(3)]),
            catalog: catalog
        ))
        XCTAssertThrowsError(try source.applying(
            .add(widget: "clock", options: [:]),
            catalog: catalog,
            makeID: { "one" }
        ))
        XCTAssertThrowsError(try source.applying(.move(id: "one", index: 0), catalog: catalog))
        XCTAssertThrowsError(try source.applying(.move(id: "one", index: 2), catalog: catalog))
        XCTAssertThrowsError(try source.applying(.move(id: "missing", index: 1), catalog: catalog))
        XCTAssertEqual(source.components.map(\.id), ["one"])
    }

    func testWriterOrdersCommitsDefersWatchReloadAndMergesUnrelatedExternalEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("shell.toml")
        try Data("profile = 'lake'\n".utf8).write(to: file)
        let entered = expectation(description: "first write entered")
        let reload = expectation(description: "deferred reload is released once")
        reload.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writes = Mutex(0)
        let commits = Mutex([UInt64]())
        let writer = ShellIslandConfigWriter(shellDirectory: directory, writeFile: { data, url in
            XCTAssertFalse(Thread.isMainThread)
            let first = writes.withLock { count in
                count += 1
                return count == 1
            }
            if first {
                entered.fulfill()
                release.wait()
            }
            try SettingsFileAccess.writeAtomically(data, at: url)
            if first {
                let external = try String(contentsOf: url, encoding: .utf8)
                let updated = try ShellTOMLText.settingNodes(
                    [(["profiles", "lake", "widgets", "clock", "format"], .string("external"))],
                    in: external
                )
                try SettingsFileAccess.writeAtomically(Data(updated.utf8), at: url)
            }
        }, reloadReady: { reload.fulfill() })
        let first = [ShellComponentInstance(id: "a", widget: "clock")]
        let second = first + [ShellComponentInstance(id: "b", widget: "clock")]
        writer.submit(write(1, change: .components(first))) { commit in
            XCTAssertNil(commit.error)
            commits.withLock { $0.append(commit.revision) }
        }
        await fulfillment(of: [entered], timeout: 2)
        writer.submit(write(2, change: .components(second))) { commit in
            XCTAssertNil(commit.error)
            commits.withLock { $0.append(commit.revision) }
        }
        XCTAssertTrue(writer.deferReloadIfWriting())
        XCTAssertTrue(writer.deferReloadIfWriting())
        release.signal()
        await writer.flush()
        await fulfillment(of: [reload], timeout: 2)
        XCTAssertFalse(writer.deferReloadIfWriting())
        XCTAssertEqual(commits.withLock { $0 }, [1, 2])
        let tree = try parsed(String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(try instances(tree).map(\.id), ["a", "b"])
        XCTAssertEqual(node(["profiles", "lake", "widgets", "clock", "format"], in: tree), .string("external"))
    }

    func testPersistenceFailureCompletesOnceWithoutRetryAndAllowsLaterWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attempts = Mutex(0)
        let errors = Mutex([String?]())
        let writer = ShellIslandConfigWriter(shellDirectory: directory, writeFile: { data, url in
            let fail = attempts.withLock { count in
                count += 1
                return count == 1
            }
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try SettingsFileAccess.writeAtomically(data, at: url)
        }, reloadReady: {})
        writer.submit(write(1, change: .components([ShellComponentInstance(id: "a", widget: "clock")]))) { commit in
            errors.withLock { $0.append(commit.error) }
        }
        writer.submit(write(2, change: .components([ShellComponentInstance(id: "b", widget: "clock")]))) { commit in
            errors.withLock { $0.append(commit.error) }
        }
        await writer.flush()
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        let results = errors.withLock { $0 }
        XCTAssertEqual(results.count, 2)
        XCTAssertNotNil(results[0])
        XCTAssertNil(results[1])
        let text = try String(contentsOf: directory.appendingPathComponent("shell.toml"), encoding: .utf8)
        XCTAssertEqual(try instances(parsed(text)).map(\.id), ["b"])
    }

    private func descriptor() -> ShellComponentDescriptor {
        ShellComponentDescriptor(
            widget: "clock",
            title: "Clock",
            icon: "clock",
            views: ["compact"],
            uses: [],
            options: [
                "zone": ShellComponentOption(kind: .string, title: "Zone", defaultValue: .string("UTC"))
            ],
            capabilities: ShellComponentCapabilities(),
            providerCommand: nil,
            folder: URL(fileURLWithPath: "/tmp/clock")
        )
    }

    private func write(_ id: UInt64, change: ShellIslandLayout.Change) -> ShellIslandConfigWriter.Write {
        ShellIslandConfigWriter.Write(
            id: ShellServiceID(owner: ShellServiceOwner(generation: 1, owner: 0, epoch: 1), request: id),
            profile: "lake",
            root: "lake",
            change: change
        )
    }

    private func parsed(_ text: String) throws -> [String: TOMLNode] {
        try TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8))
    }

    private func instances(_ tree: [String: TOMLNode]) throws -> [ShellComponentInstance] {
        try ShellComponentCatalog.instances(from: node(["profiles", "lake", "island", "components"], in: tree))
    }

    private func node(_ path: [String], in tree: [String: TOMLNode]) -> TOMLNode? {
        var node = TOMLNode.table(tree)
        for key in path {
            guard case let .table(table) = node, let next = table[key] else { return nil }
            node = next
        }
        return node
    }
}
