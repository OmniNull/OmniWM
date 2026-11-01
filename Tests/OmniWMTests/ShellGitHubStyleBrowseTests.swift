// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

struct ShellGitHubStyleBrowseFixture {
    struct Reply: Sendable {
        let data: Data
        var status = 200
        var error: URLError?
    }

    private struct State {
        var replies: [String: Reply] = [:]
        var requests: [String] = []
    }

    private final class GitHub: URLProtocol {
        static let state = Mutex(State())

        override static func canInit(with _: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let reply = Self.state.withLock { state in
                state.requests.append(url.absoluteString)
                return state.replies[url.absoluteString] ?? Reply(data: Data(), status: 404)
            }
            if let error = reply.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: nil,
                headerFields: nil
            )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    let owner = "studio"
    let repository = "glass"
    let branch = "styles/current"
    let commit = "snapshot-a"
    let rootTree = "root-tree-a"
    let styleTree = "style-tree-a"
    let name = "probe"
    let preview = "bar.png"
    let files: [ShellStyleFile]
    let root: Bool
    let session: URLSession

    var address: String {
        "https://github.com/\(owner)/\(repository)"
    }

    var api: String {
        "https://api.github.com/repos/\(owner)/\(repository)"
    }

    var raw: String {
        "https://raw.githubusercontent.com/\(owner)/\(repository)/\(commit)"
    }

    var folder: String {
        root ? raw : "\(raw)/\(ShellGitHubStyleSource.folder)/\(name)"
    }

    var revision: String {
        root ? rootTree : styleTree
    }

    var commitURL: String {
        "\(api)/commits/\(branch.replacingOccurrences(of: "/", with: "%2F"))"
    }

    var collectionURL: String {
        "\(api)/contents/\(ShellGitHubStyleSource.folder)?ref=\(commit)"
    }

    var treeURL: String {
        "\(api)/git/trees/\(revision)?recursive=1"
    }

    var requests: [String] {
        GitHub.state.withLock { $0.requests }
    }

    init(root: Bool = true) throws {
        self.root = root
        let manifest = Self.manifest(name: name, previews: [preview])
        files = [
            ShellStyleFile(path: ShellStyleManifest.fileName, data: manifest, executable: false),
            ShellStyleFile(path: "shell.toml", data: Data("[workspaceBar]\n".utf8), executable: false),
            ShellStyleFile(path: "lib/pieces.luau", data: Data("return {}".utf8), executable: false),
            ShellStyleFile(path: "bin/helper", data: Data("fixture executable".utf8), executable: true)
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHub.self]
        session = URLSession(configuration: configuration)
        GitHub.state.withLock { $0 = State() }
        try reply(["default_branch": branch], at: api)
        try reply(["sha": commit, "commit": ["tree": ["sha": rootTree]]], at: commitURL)
        if !root { try reply([["name": name, "type": "dir", "sha": styleTree]], at: collectionURL) }
        for file in files { reply(file.data, at: "\(folder)/\(file.path)") }
        var items = files.map { item(path: $0.path, mode: $0.executable ? "100755" : "100644") }
        items += [
            item(path: "lib", mode: "040000", type: "tree"),
            item(path: "previews/\(preview)"),
            item(path: ".hidden"),
            item(path: "lib/.hidden")
        ]
        try reply(["tree": items, "truncated": false], at: treeURL)
    }

    func reply(_ data: Data, at address: String, status: Int = 200, error: URLError? = nil) {
        GitHub.state.withLock { $0.replies[address] = Reply(data: data, status: status, error: error) }
    }

    func reply(_ object: Any, at address: String, status: Int = 200) throws {
        reply(try JSONSerialization.data(withJSONObject: object), at: address, status: status)
    }

    func item(path: String, mode: String = "100644", type: String = "blob") -> [String: String] {
        ["path": path, "mode": mode, "type": type]
    }

    static func manifest(name: String, previews: [String] = [], api: Int = ShellStyleManifest.api) -> Data {
        Data("""
        format = \(ShellStyleManifest.format)
        api = \(api)
        name = "\(name)"
        version = "1.2.3"
        title = "\(name.capitalized)"
        summary = "A fixture style"
        previews = [\(previews.map { "\"\($0)\"" }.joined(separator: ", "))]
        """.utf8)
    }
}

final class ShellGitHubStyleBrowseTests: XCTestCase {
    func testRepositoryMainPageURLsNormalizeTheirIdentity() throws {
        let addresses = [
            "https://github.com/Studio/Glass", "https://github.com/Studio/Glass/",
            "https://github.com/Studio/Glass.git", " https://GITHUB.COM/Studio/Glass.git/\n"
        ]
        let expected = try ShellGitHubStyleSource.Repository("https://github.com/studio/glass")
        for address in addresses {
            XCTAssertEqual(try ShellGitHubStyleSource.Repository(address), expected, address)
        }
        XCTAssertEqual(expected.owner, "studio")
        XCTAssertEqual(expected.name, "glass")
    }

    func testOnlyPublicRepositoryMainPageURLsAreAccepted() {
        let invalid = [
            "", "studio/glass", "http://github.com/studio/glass", "https://gitlab.com/studio/glass",
            "https://github.com/studio", "https://github.com/studio/glass/tree/main",
            "https://github.com/studio//glass", "https://github.com/studio/glass//",
            "https://user@github.com/studio/glass", "https://github.com:443/studio/glass",
            "https://github.com/studio/glass?ref=main", "https://github.com/studio/glass#readme",
            "https://github.com/studio/.git", "https://github.com/studio/../", "https://github.com/studio/gla%2Fss"
        ]
        for address in invalid {
            XCTAssertThrowsError(try ShellGitHubStyleSource.Repository(address), address)
        }
    }

    func testRootStyleUsesItsManifestNameAndOnePinnedCommitForAllFiles() async throws {
        let fixture = try fixture()
        let browse = try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session)
        let listing = try XCTUnwrap(browse.listings.first)
        XCTAssertEqual(browse.listings.map(\.name), [fixture.name])
        XCTAssertEqual(listing.revision, fixture.rootTree)
        XCTAssertEqual(listing.previews, [URL(string: "\(fixture.folder)/previews/\(fixture.preview)")!])
        XCTAssertEqual(browse.source.ref, fixture.commit)
        XCTAssertEqual(browse.source.repositoryName, "\(fixture.owner)/\(fixture.repository)")
        XCTAssertTrue(browse.problems.isEmpty)
        XCTAssertEqual(fixture.requests, [
            fixture.api,
            fixture.commitURL,
            "\(fixture.raw)/\(ShellStyleManifest.fileName)"
        ])
        let nextCommit = "snapshot-b"
        try fixture.reply(["sha": nextCommit, "commit": ["tree": ["sha": "root-tree-b"]]], at: fixture.commitURL)
        fixture.reply(Data("changed on branch".utf8), at: "\(fixture.raw)/lib/pieces.luau".replacingOccurrences(
            of: fixture.commit, with: nextCommit
        ))
        let payload = try await browse.source.payload(for: listing)
        XCTAssertEqual(payload.files, fixture.files.sorted { $0.path < $1.path })
        XCTAssertEqual(payload.source, "github:\(fixture.owner)/\(fixture.repository)@\(fixture.branch)")
        XCTAssertFalse(fixture.requests.contains { $0.contains(nextCommit) })
        XCTAssertEqual(fixture.requests.filter { $0.contains("/commits/") }, [fixture.commitURL])
        let shell = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shell) }
        try ShellStyleInstaller.install(payload, into: shell, replacing: false)
        let installed = shell.appending(path: listing.name)
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: installed)?.source, payload.source)
        for file in fixture.files {
            let path = installed.appending(path: file.path)
            XCTAssertEqual(try Data(contentsOf: path), file.data)
            let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, file.executable ? 0o755 : 0o644)
        }
    }

    func testCollectionUsesThePinnedFolderTreeAndKeepsGoodSiblings() async throws {
        let fixture = try fixture(root: false)
        let invalid = "broken", incompatible = "future", mismatch = "wrong-name"
        let entries = [fixture.name, invalid, incompatible, mismatch].map {
            ["name": $0, "type": "dir", "sha": $0 == fixture.name ? fixture.styleTree : "\($0)-tree"]
        }
        try fixture.reply(entries, at: fixture.collectionURL)
        let rawStyles = "\(fixture.raw)/\(ShellGitHubStyleSource.folder)"
        fixture.reply(Data("bad TOML [".utf8), at: "\(rawStyles)/\(invalid)/\(ShellStyleManifest.fileName)")
        fixture.reply(
            ShellGitHubStyleBrowseFixture.manifest(name: incompatible, api: ShellStyleManifest.api + 1),
            at: "\(rawStyles)/\(incompatible)/\(ShellStyleManifest.fileName)"
        )
        fixture.reply(
            ShellGitHubStyleBrowseFixture.manifest(name: fixture.name),
            at: "\(rawStyles)/\(mismatch)/\(ShellStyleManifest.fileName)"
        )
        let browse = try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session)
        XCTAssertEqual(browse.listings.map(\.name), [fixture.name])
        XCTAssertEqual(browse.problems.count, [invalid, incompatible, mismatch].count)
        for name in [invalid, incompatible, mismatch] {
            XCTAssertTrue(browse.problems.contains { $0.hasPrefix(name + ":") })
        }
        let listing = try XCTUnwrap(browse.listings.first)
        XCTAssertEqual(listing.revision, fixture.styleTree)
        XCTAssertEqual(listing.previews.first, URL(string: "\(fixture.folder)/previews/\(fixture.preview)"))
        let payload = try await browse.source.payload(for: listing)
        XCTAssertEqual(payload.files, fixture.files.sorted { $0.path < $1.path })
    }

    func testRootManifestTakesPrecedenceOverACollection() async throws {
        let fixture = try fixture()
        try fixture.reply([["name": "other", "type": "dir", "sha": "other-tree"]], at: fixture.collectionURL)
        let browse = try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session)
        XCTAssertEqual(browse.listings.map(\.name), [fixture.name])
        XCTAssertFalse(fixture.requests.contains(fixture.collectionURL))
    }

    func testOnlyAMissingRootManifestFallsBackToTheCollection() async throws {
        let fixture = try fixture(root: false)
        let manifestURL = "\(fixture.raw)/\(ShellStyleManifest.fileName)"
        fixture.reply(Data("invalid [".utf8), at: manifestURL)
        await assertRefused { try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session) }
        XCTAssertFalse(fixture.requests.contains(fixture.collectionURL))
        fixture.reply(Data(), at: manifestURL, error: URLError(.notConnectedToInternet))
        await assertRefused { try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session) }
        XCTAssertFalse(fixture.requests.contains(fixture.collectionURL))
    }

    func testGitHubRateLimitMessageIsShownWithoutRetry() async throws {
        let fixture = try fixture()
        let message = "API rate limit exceeded for fixture"
        try fixture.reply(["message": message], at: fixture.api, status: 403)
        do {
            _ = try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session)
            XCTFail("A rate-limited request succeeded")
        } catch {
            XCTAssertEqual(error.localizedDescription, message)
        }
        XCTAssertEqual(fixture.requests, [fixture.api])
    }

    func testARepositoryWithNoStylesExplainsTheSupportedLayouts() async throws {
        let fixture = try fixture(root: false)
        fixture.reply(Data(), at: fixture.collectionURL, status: 404)
        do {
            _ = try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session)
            XCTFail("The repository has no styles")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("style.toml"))
            XCTAssertTrue(error.localizedDescription.contains("styles/<name>/style.toml"))
        }
    }

    func testEmptyCollectionExplainsThatNoInstallableStyleWasFound() async throws {
        let fixture = try fixture(root: false)
        try fixture.reply([[String: String]](), at: fixture.collectionURL)
        let browse = try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session)
        XCTAssertTrue(browse.listings.isEmpty)
        XCTAssertTrue(try XCTUnwrap(browse.problems.first).contains("no installable styles"))
    }

    func testLinksAndSubmodulesAreNotTurnedIntoRegularFiles() async throws {
        let fixture = try fixture()
        let browse = try await ShellGitHubStyleSource.browse(fixture.address, session: fixture.session)
        let listing = try XCTUnwrap(browse.listings.first)
        for item in [
            fixture.item(path: "linked", mode: "120000"),
            fixture.item(path: "submodule", mode: "160000", type: "commit")
        ] {
            try fixture.reply(["tree": [item], "truncated": false], at: fixture.treeURL)
            await assertRefused { try await browse.source.payload(for: listing) }
        }
    }

    private func fixture(root: Bool = true) throws -> ShellGitHubStyleBrowseFixture {
        let fixture = try ShellGitHubStyleBrowseFixture(root: root)
        addTeardownBlock { fixture.session.invalidateAndCancel() }
        return fixture
    }

    private func assertRefused<Value>(
        _ operation: () async throws -> Value, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("GitHub's reply was accepted", file: file, line: line)
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }
}
