// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreServices
import Darwin
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellDirectoryObservationTests: XCTestCase {
    func testLinkedShellContentNeverRecursivelyWatchesAncestors() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = try directory("config", in: root)
        let aliases = try directory("aliases", in: root)
        let shell = try directory("targets/first/shell", in: root)
        let profile = try directory("profile", in: root)
        let sources = try directory("sources", in: root)
        try Data("profile = 'selected'\n".utf8).write(to: shell.appendingPathComponent("shell.toml"))
        try Data("theme = 'native'\n".utf8).write(to: profile.appendingPathComponent("shell.toml"))
        try Data("return {}\n".utf8).write(to: sources.appendingPathComponent("shared.luau"))
        try FileManager.default.createSymbolicLink(
            atPath: aliases.appendingPathComponent("current").path,
            withDestinationPath: "../targets/first"
        )
        try FileManager.default.createSymbolicLink(
            atPath: configDirectory.appendingPathComponent("current").path,
            withDestinationPath: "../aliases/current"
        )
        try FileManager.default.createSymbolicLink(
            atPath: shell.appendingPathComponent("selected").path,
            withDestinationPath: "../../../profile"
        )
        try FileManager.default.createSymbolicLink(
            atPath: shell.appendingPathComponent("linked-source.luau").path,
            withDestinationPath: "../../../sources/shared.luau"
        )
        let requestedShell = configDirectory.appendingPathComponent("current/shell")
        var config = ShellConfig()
        config.profile = "selected"
        config.directories = [requestedShell, requestedShell.appendingPathComponent("selected")]
        let inputs = try ShellConfigurationInputs(directory: requestedShell, config: config)
        XCTAssertTrue(inputs.paths.contains { $0.path == "/" })
        var attempts: [[String]] = []
        let observation = ShellDirectoryObservation(watchLinks: true, startStream: { stream in
            attempts.append(FSEventStreamCopyPathsBeingWatched(stream) as? [String] ?? [])
            return false
        }) {}
        defer { observation.cancel() }

        observation.sync(paths: inputs.paths, recursivePaths: inputs.recursivePaths)

        let expected = Set([shell.path, profile.path, sources.path])
        XCTAssertEqual(attempts.count, 1)
        let watched = try XCTUnwrap(attempts.first)
        XCTAssertEqual(Set(watched), expected)
        XCTAssertFalse(watched.contains("/"))
        for watchedRoot in watched {
            XCTAssertFalse(expected.contains { $0.hasPrefix(watchedRoot + "/") })
        }
    }

    func testMissingContentNeverWidensItsRecursiveRoot() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let paths = Array(SettingsFileObservationDirectories.paths(for: missing)) + [missing]
        var attempts: [[String]] = []
        let observation = ShellDirectoryObservation(watchLinks: true, createStream: { _, roots in
            attempts.append(roots)
            return nil
        }) {}
        defer { observation.cancel() }

        observation.sync(paths: paths, recursivePaths: [missing])

        XCTAssertTrue(attempts.isEmpty)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        observation.sync(paths: paths, recursivePaths: [missing])

        XCTAssertEqual(attempts, [[missing.path]])
    }

    func testExplicitResyncRetargetsOnlyTheRequestedContentDirectory() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try directory("first", in: root)
        let second = try directory("second", in: root)
        let link = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "first")
        var attempts: [[String]] = []
        let observation = ShellDirectoryObservation(watchLinks: true, createStream: { _, roots in
            attempts.append(roots)
            return nil
        }) {}
        defer { observation.cancel() }
        let paths = Array(SettingsFileObservationDirectories.paths(for: link)) + [link]

        observation.sync(paths: paths, recursivePaths: [link])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "second")
        observation.sync(paths: paths, recursivePaths: [link])

        XCTAssertEqual(attempts, [[first.path], [second.path]])
    }

    func testRetargetKeepsNativeObservationWithStaleEnumeratedDirectories() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try directory("first", in: root)
        let second = try directory("second", in: root)
        let stale = try (0 ..< 64).map { try directory("first/stale-\($0)", in: root) }
        let link = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "first")
        let paths = Array(SettingsFileObservationDirectories.paths(for: link)) + [link] + stale
        var attempts: [[String]] = []
        let rearmed = expectation(description: "Retargeted native stream starts after retirement")
        let observation = ShellDirectoryObservation(watchLinks: true, startStream: { stream in
            let roots = FSEventStreamCopyPathsBeingWatched(stream) as? [String] ?? []
            attempts.append(roots)
            let started = FSEventStreamStart(stream)
            if started, roots == [second.path] { rearmed.fulfill() }
            return started
        }) {}
        defer { observation.cancel() }

        observation.sync(paths: paths, recursivePaths: [link])
        XCTAssertTrue(observation.isUsingNativeObservation)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "second")
        observation.sync(paths: paths, recursivePaths: [link])
        await fulfillment(of: [rearmed], timeout: failureBound)

        XCTAssertEqual(attempts, [[first.path], [second.path]])
        XCTAssertTrue(observation.isUsingNativeObservation)
    }

    func testIdleResyncKeepsNativeObservationWithoutCheckingDescriptorReserve() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try directory("content", in: root)
        let reserve = DescriptorReserve()
        var starts = 0
        let observation = ShellDirectoryObservation(watchLinks: true, startStream: { stream in
            starts += 1
            return FSEventStreamStart(stream)
        }, hasDescriptorReserve: { _ in
            reserve.checks += 1
            return reserve.available
        }) {}
        defer { observation.cancel() }

        observation.sync(paths: [content], recursivePaths: [content])
        let initialReserveChecks = reserve.checks
        XCTAssertGreaterThan(initialReserveChecks, 0)
        XCTAssertTrue(observation.isUsingNativeObservation)

        reserve.available = false
        observation.sync(paths: [content], recursivePaths: [content])

        XCTAssertEqual(reserve.checks, initialReserveChecks)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(observation.isUsingNativeObservation)
    }

    func testNativeOnlyObservationNeverOpensShallowDirectories() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try directory("content", in: root)
        let paths = Array(SettingsFileObservationDirectories.paths(for: content)) + [content]
        var opened: [String] = []
        let observation = ShellDirectoryObservation(watchLinks: false, openDirectory: { path in
            opened.append(path)
            return -1
        }) {}
        defer { observation.cancel() }

        observation.sync(paths: paths, recursivePaths: [content])

        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(observation.isUsingNativeObservation)
    }

    func testDeniedShallowDirectoryDoesNotDemoteNativeObservation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try directory("content", in: root)
        let link = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: content)
        var opened: [String] = []
        let observation = ShellDirectoryObservation(watchLinks: true, openDirectory: { path in
            opened.append(path)
            return -1
        }) {}
        defer { observation.cancel() }

        observation.sync(paths: [link], recursivePaths: [link])

        XCTAssertFalse(opened.isEmpty)
        XCTAssertTrue(observation.isUsingNativeObservation)

        observation.sync(paths: [link], recursivePaths: [link])

        XCTAssertTrue(observation.isUsingNativeObservation)
    }

    func testPlainContentNeedsNoShallowDirectoryOpens() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try directory("nested/content", in: root)
        let paths = Array(SettingsFileObservationDirectories.paths(for: content)) + [content]
        var opened: [String] = []
        let observation = ShellDirectoryObservation(watchLinks: true, openDirectory: { path in
            opened.append(path)
            return Darwin.open(path, O_EVTONLY)
        }) {}
        defer { observation.cancel() }

        observation.sync(paths: paths, recursivePaths: [content])

        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(observation.isUsingNativeObservation)
    }

    func testMissingLinkedContentObservesItsResolvedParentAndStartsWhenCreated() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try directory("targets/B", in: root)
        let missing = parent.appendingPathComponent("missing")
        let link = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "targets/B/missing")
        let changed = expectation(description: "Missing linked content directory created")
        changed.assertForOverFulfill = false
        var opened: [String] = []
        var attempts: [[String]] = []
        let observation = ShellDirectoryObservation(watchLinks: true, startStream: { stream in
            attempts.append(FSEventStreamCopyPathsBeingWatched(stream) as? [String] ?? [])
            return FSEventStreamStart(stream)
        }, openDirectory: { path in
            opened.append(path)
            return Darwin.open(path, O_EVTONLY)
        }) { changed.fulfill() }
        defer { observation.cancel() }

        observation.sync(paths: [link], recursivePaths: [link])

        XCTAssertTrue(opened.contains(parent.path))
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertFalse(observation.isUsingNativeObservation)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        await fulfillment(of: [changed], timeout: failureBound)

        XCTAssertEqual(attempts, [[missing.path]])
        XCTAssertTrue(observation.isUsingNativeObservation)
    }

    @MainActor
    private final class DescriptorReserve {
        var available = true
        var checks = 0
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OmniWMObservation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SettingsFileAccess.canonicalURL(for: root)
    }

    private func directory(_ path: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
