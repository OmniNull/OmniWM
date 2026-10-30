// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellGitHubStyleSourceTests: XCTestCase {
    private final class GitHub: URLProtocol {
        static let files = Mutex<[String: Data]>([:])

        static func address(of url: URL) -> String {
            "\(url.scheme ?? "")://\(url.host() ?? "")\(url.path(percentEncoded: false))"
                + (url.query().map { "?\($0)" } ?? "")
        }

        override static func canInit(with _: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let data = request.url.flatMap { url in Self.files.withLock { $0[Self.address(of: url)] } }
            guard let url = request.url, let response = HTTPURLResponse(
                url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: [:]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private struct Entry: Encodable {
        let name: String
        let type: String
        let sha: String
    }

    private struct Item: Encodable {
        let path: String
        let mode: String
        let type: String
    }

    private struct Tree: Encodable {
        let tree: [Item]
        var truncated = false
    }

    private static let owner = "OmniNull"
    private static let repository = "OmniWM"
    private static let ref = "fixture"
    private static let api = "https://api.github.com/repos/\(owner)/\(repository)/"
    private static let raw = "https://raw.githubusercontent.com/\(owner)/\(repository)/\(ref)/\(ShellGitHubStyleSource.folder)/"
    private static let folderMode = "040000"
    private static let fileMode = "100644"
    private static let executableMode = "100755"

    private let checkout = ShellStyleRepository(folder: ShellStyleFixture.directory)

    func testEachStyleFolderArrivesFromGitHubAsTheCheckoutHasIt() async throws {
        try serveCheckout()
        let source = source()
        let listings = try await source.styles()
        let expected = try checkout.styles()
        XCTAssertEqual(listings.map(\.name), expected.map(\.name))
        XCTAssertEqual(listings.map(\.manifest), expected.map(\.manifest))
        for listing in listings {
            let payload = try await source.payload(for: listing)
            XCTAssertEqual(payload.files, try checkout.files(of: listing.name), listing.name)
            XCTAssertEqual(payload.source, source.source)
        }
    }

    func testAFolderGitHubListsOnlyInPartIsRefused() async throws {
        let style = try XCTUnwrap(checkout.styles().first)
        try serveCheckout { name, tree in tree.truncated = name == style.name }
        let source = source()
        let listing = try await listing(style.name, in: source)
        await assertRefused { try await source.payload(for: listing) }
    }

    func testAFileGitHubCannotSendStopsTheWholeFolder() async throws {
        let style = try XCTUnwrap(checkout.styles().first)
        let missing = try XCTUnwrap(checkout.files(of: style.name).last)
        try serveCheckout()
        GitHub.files.withLock { $0["\(Self.raw)\(style.name)/\(missing.path)"] = nil }
        let source = source()
        let listing = try await listing(style.name, in: source)
        await assertRefused { try await source.payload(for: listing) }
    }

    func testAFolderWhoseManifestNamesAnotherStyleIsRefused() async throws {
        let styles = try checkout.styles()
        let folder = try XCTUnwrap(styles.first)
        let other = try XCTUnwrap(styles.last)
        XCTAssertNotEqual(folder.name, other.name)
        try serveCheckout()
        GitHub.files.withLock {
            $0["\(Self.raw)\(folder.name)/\(ShellStyleManifest.fileName)"] =
                $0["\(Self.raw)\(other.name)/\(ShellStyleManifest.fileName)"]
        }
        let source = source()
        await assertRefused { try await source.styles() }
    }

    private func serveCheckout(editing edit: (String, inout Tree) -> Void = { _, _ in }) throws {
        var files: [String: Data] = [:]
        var entries: [Entry] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: ShellStyleFixture.directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            let name = url.lastPathComponent
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                entries.append(Entry(name: name, type: "file", sha: name))
                continue
            }
            entries.append(Entry(name: name, type: "dir", sha: name))
            let styleFiles = try checkout.files(of: name)
            let folders = Set(styleFiles.flatMap { file in
                let components = file.path.split(separator: "/")
                return components.indices.dropLast().map { components[...$0].joined(separator: "/") }
            })
            var tree = Tree(tree: folders.map { Item(path: $0, mode: Self.folderMode, type: "tree") } + [
                Item(path: ShellStyleRepository.previewsFolder, mode: Self.folderMode, type: "tree"),
                Item(path: "\(ShellStyleRepository.previewsFolder)/bar.png", mode: Self.fileMode, type: "blob"),
                Item(path: ".DS_Store", mode: Self.fileMode, type: "blob")
            ] + styleFiles.map {
                Item(path: $0.path, mode: $0.executable ? Self.executableMode : Self.fileMode, type: "blob")
            })
            edit(name, &tree)
            files["\(Self.api)git/trees/\(name)?recursive=1"] = try JSONEncoder().encode(tree)
            for file in styleFiles {
                files["\(Self.raw)\(name)/\(file.path)"] = file.data
            }
        }
        files["\(Self.api)contents/\(ShellGitHubStyleSource.folder)?ref=\(Self.ref)"] = try JSONEncoder()
            .encode(entries)
        GitHub.files.withLock { $0 = files }
    }

    private func source() -> ShellGitHubStyleSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHub.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return ShellGitHubStyleSource(owner: Self.owner, repository: Self.repository, ref: Self.ref, session: session)
    }

    private func listing(_ name: String, in source: ShellGitHubStyleSource) async throws -> ShellStyleListing {
        let listings = try await source.styles()
        return try XCTUnwrap(listings.first { $0.name == name })
    }

    private func assertRefused<Value>(
        _ operation: () async throws -> Value, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("GitHub's reply was accepted", file: file, line: line)
        } catch {
            XCTAssertTrue(error is ShellStyleInstaller.Failure, "\(error)", file: file, line: line)
        }
    }
}
