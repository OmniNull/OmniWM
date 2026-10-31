// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CryptoKit
import Darwin
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellProviderObservationTests: XCTestCase {
    private func fixture(_ directory: URL, instance: String = "child") throws -> ShellProviderConfiguration {
        let executable = directory.appendingPathComponent("bin/provider")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return try .fixture(widget: "fixture", instance: instance, folder: directory, command: ["bin/provider"])
    }

    private func watchPaths(for configuration: ShellProviderConfiguration) -> Set<String> {
        let executable = configuration.folder.appendingPathComponent(configuration.command[0])
        return Set([
            executable, executable.deletingLastPathComponent(),
            configuration.folder, configuration.folder.deletingLastPathComponent()
        ].map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
    }

    private func watchDescriptorCount(under directory: URL) -> Int {
        let root = directory.resolvingSymlinksInPath().path
        return (0 ..< min(getdtablesize(), 4096)).filter { descriptor in
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, flags & O_EVTONLY != 0 else { return false }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return false }
            let rawPath = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let path = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }.count
    }

    func testManyUnapprovedInstancesShareWatchesUntilTheLastSubscriberCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try fixture(directory.appendingPathComponent("component"))
        let approved = expectation(description: "Every instance requests approval")
        let instanceCount = 64
        approved.expectedFulfillmentCount = instanceCount
        let inbox = ShellProviderInbox()
        var providers: [ShellProvider] = []
        for index in 0 ..< instanceCount {
            let owner = ShellServiceOwner(generation: 781, owner: UInt32(index + 1), epoch: 1)
            let provider = ShellProvider(owner: owner, inbox: inbox, trustNeeded: { _ in approved.fulfill() })
            providers.append(provider)
            await provider.reconcile(ShellProviderConfiguration(
                widget: configuration.widget, instance: "instance-\(index)", folder: configuration.folder,
                command: configuration.command, options: configuration.options, sha256: nil
            ))
            XCTAssertEqual(inbox.binding(for: owner)?.status, .notApproved)
        }
        await fulfillment(of: [approved], timeout: 10)
        let expectedCount = watchPaths(for: configuration).count
        XCTAssertEqual(watchDescriptorCount(under: directory), expectedCount)
        for provider in providers.dropLast() { await provider.close() }
        XCTAssertEqual(watchDescriptorCount(under: directory), expectedCount)
        await providers.last?.close()
        XCTAssertEqual(watchDescriptorCount(under: directory), 0)
    }

    func testCloseWaitsForWatchesRemovedByReconciliation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try fixture(directory.appendingPathComponent("component")).unapproved
        let approved = expectation(description: "Provider requests approval")
        let provider = ShellProvider(
            owner: .init(generation: 788, owner: 1, epoch: 1), inbox: ShellProviderInbox(),
            trustNeeded: { _ in approved.fulfill() }
        )
        await provider.reconcile(configuration)
        await fulfillment(of: [approved], timeout: 10)
        XCTAssertEqual(watchDescriptorCount(under: directory), watchPaths(for: configuration).count)
        await provider.reconcile(nil)
        await provider.close()
        XCTAssertEqual(watchDescriptorCount(under: directory), 0)
    }

    func testCanonicalPathsShareWatchesAcrossComponentAliases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try fixture(directory.appendingPathComponent("component"))
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: configuration.folder)
        let linked = ShellProviderConfiguration(
            widget: configuration.widget, instance: "linked", folder: alias,
            command: configuration.command, options: configuration.options, sha256: nil
        )
        let approved = expectation(description: "Both paths request approval")
        let configurations = [configuration.unapproved, linked]
        approved.expectedFulfillmentCount = configurations.count
        var providers: [ShellProvider] = []
        for (index, configuration) in configurations.enumerated() {
            let provider = ShellProvider(
                owner: .init(generation: 782, owner: UInt32(index + 1), epoch: 1), inbox: ShellProviderInbox(),
                trustNeeded: { _ in approved.fulfill() }
            )
            providers.append(provider)
            await provider.reconcile(configuration)
        }
        await fulfillment(of: [approved], timeout: 10)
        let expectedPaths = configurations.reduce(into: Set<String>()) { $0.formUnion(watchPaths(for: $1)) }
        XCTAssertEqual(watchDescriptorCount(under: directory), expectedPaths.count)
        await providers[0].close()
        XCTAssertEqual(watchDescriptorCount(under: directory), watchPaths(for: linked).count)
        await providers[1].close()
        XCTAssertEqual(watchDescriptorCount(under: directory), 0)
    }

    func testSharedSubscribersObserveRepeatedAtomicReplacementsAfterAPeerCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try fixture(directory.appendingPathComponent("component"))
        let instanceCount = 3
        let initial = expectation(description: "Every subscriber requests initial approval")
        initial.expectedFulfillmentCount = instanceCount
        let revisions = (1 ... 2).map { revision in
            let bytes = Data("#!/bin/sh\nexit \(revision)\n".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let event = expectation(description: "Remaining subscribers approve revision \(revision)")
            event.expectedFulfillmentCount = instanceCount - 1
            return (bytes: bytes, digest: digest, event: event)
        }
        let approvals = Mutex<[String: Set<Int>]>([:])
        var providers: [ShellProvider] = []
        for index in 0 ..< instanceCount {
            let provider = ShellProvider(
                owner: .init(generation: 783, owner: UInt32(index + 1), epoch: 1), inbox: ShellProviderInbox(),
                trustNeeded: { approval in
                    let inserted = approvals.withLock { $0[approval.sha256, default: []].insert(index).inserted }
                    guard inserted else { return }
                    if approval.sha256 == configuration.sha256 { initial.fulfill() }
                    for revision in revisions where revision.digest == approval.sha256 { revision.event.fulfill() }
                }
            )
            providers.append(provider)
            await provider.reconcile(configuration.unapproved)
        }
        await fulfillment(of: [initial], timeout: 10)
        await providers[0].close()
        let executable = configuration.folder.appendingPathComponent(configuration.command[0])
        for revision in revisions {
            try revision.bytes.write(to: executable, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            await fulfillment(of: [revision.event], timeout: 10)
            XCTAssertEqual(approvals.withLock { $0[revision.digest] }, Set(providers.indices.dropFirst()))
        }
        for provider in providers { await provider.close() }
        XCTAssertEqual(watchDescriptorCount(under: directory), 0)
    }

    func testConcurrentReconciliationSharesWatchesAndConcurrentCloseReleasesThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try fixture(directory.appendingPathComponent("component")).unapproved
        let approved = expectation(description: "Concurrent instances request approval")
        let providers = (0 ..< 64).map {
            ShellProvider(
                owner: .init(generation: 786, owner: UInt32($0 + 1), epoch: 1), inbox: ShellProviderInbox(),
                trustNeeded: { _ in approved.fulfill() }
            )
        }
        approved.expectedFulfillmentCount = providers.count
        await withTaskGroup(of: Void.self) { group in
            for provider in providers { group.addTask { await provider.reconcile(configuration) } }
        }
        await fulfillment(of: [approved], timeout: 10)
        XCTAssertEqual(watchDescriptorCount(under: directory), watchPaths(for: configuration).count)
        await withTaskGroup(of: Void.self) { group in
            for provider in providers { group.addTask { await provider.close() } }
        }
        XCTAssertEqual(watchDescriptorCount(under: directory), 0)
    }

    func testComponentLinkRetargetingStillObservesAnInitiallyMissingExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try fixture(directory.appendingPathComponent("first"))
        let second = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(
            at: second.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        let link = directory.appendingPathComponent("links/component")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first.folder)
        let configuration = ShellProviderConfiguration(
            widget: "fixture", instance: "child", folder: link, command: ["bin/provider"],
            options: Data("{}".utf8), sha256: nil
        )
        let initial = expectation(description: "Initial target requests approval")
        let missing = expectation(description: "Retargeted executable is missing")
        missing.assertForOverFulfill = false
        let recovered = expectation(description: "Created executable requests approval")
        let bytes = Data("#!/bin/sh\nexit 17\n".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let provider = ShellProvider(
            owner: .init(generation: 787, owner: 1, epoch: 1), inbox: ShellProviderInbox(),
            trustNeeded: { approval in
                if approval.sha256 == first.sha256 { initial.fulfill() }
                if approval.sha256 == digest { recovered.fulfill() }
            },
            diagnostics: { _, _ in missing.fulfill() }
        )
        await provider.reconcile(configuration)
        await fulfillment(of: [initial], timeout: 10)
        XCTAssertEqual(watchDescriptorCount(under: directory), watchPaths(for: configuration).count)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        await fulfillment(of: [missing], timeout: 10)
        let executable = second.appendingPathComponent("bin/provider")
        try bytes.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        await fulfillment(of: [recovered], timeout: 10)
        await provider.close()
        XCTAssertEqual(watchDescriptorCount(under: directory), 0)
    }
}
