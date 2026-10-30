// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

protocol ShellStyleSource: Sendable {
    func styles() async throws -> [ShellStyleListing]
    func payload(for listing: ShellStyleListing) async throws -> ShellStylePayload
}

struct ShellGitHubStyleSource: ShellStyleSource {
    private struct Entry: Decodable {
        let name: String
        let type: String
        let sha: String
    }

    private struct TreeItem: Decodable {
        let path: String
        let mode: String
        let type: String
    }

    private struct Tree: Decodable {
        let tree: [TreeItem]
        let truncated: Bool
    }

    static let folder = "styles"

    let owner: String
    let repository: String
    let ref: String
    var session: URLSession = .shared

    var source: String {
        "github:\(owner)/\(repository)@\(ref)"
    }

    static func official(bundle: Bundle = .main) -> Self? {
        guard let ref = bundle.canaryReleaseTag ?? bundle.appVersion.map({ "v" + $0 }) else { return nil }
        return Self(owner: "OmniNull", repository: "OmniWM", ref: ref)
    }

    func styles() async throws -> [ShellStyleListing] {
        let entries = try await decode(
            [Entry].self,
            from: api("contents/\(Self.folder)", .init(name: "ref", value: ref))
        )
        var listings: [ShellStyleListing] = []
        for entry in entries where entry.type == "dir" && ShellProfiles.isStyleName(entry.name) {
            let folder = folder(of: entry.name)
            let manifest = try await fetch(folder.appending(path: ShellStyleManifest.fileName))
            listings.append(try ShellStyleListing(
                name: entry.name, manifest: ShellStyleManifest.parse(manifest), folder: folder, revision: entry.sha
            ))
        }
        return listings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func payload(for listing: ShellStyleListing) async throws -> ShellStylePayload {
        guard let revision = listing.revision
        else { throw ShellStyleInstaller.Failure("\(listing.name) has no revision") }
        let tree = try await decode(Tree.self, from: api("git/trees/\(revision)", .init(name: "recursive", value: "1")))
        guard !tree.truncated else { throw ShellStyleInstaller.Failure("GitHub listed only part of \(listing.name)") }
        var files: [ShellStyleFile] = []
        for item in tree.tree where item.type == "blob" && Self.installs(item.path) {
            let data = try await fetch(folder(of: listing.name).appending(path: item.path))
            files.append(ShellStyleFile(path: item.path, data: data, executable: item.mode == "100755"))
        }
        return ShellStylePayload(name: listing.name, source: source, files: files.sorted { $0.path < $1.path })
    }

    private static func installs(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.first.map(String.init) != ShellStyleRepository.previewsFolder
            && !components.contains { $0.hasPrefix(".") }
    }

    private func api(_ path: String, _ query: URLQueryItem) -> URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)")!
            .appending(path: path)
            .appending(queryItems: [query])
    }

    private func folder(of style: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(ref)/\(Self.folder)")!
            .appending(path: style)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) async throws -> Value {
        try JSONDecoder().decode(type, from: await fetch(url))
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OmniWM", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ... 299).contains(status) else {
            throw ShellStyleInstaller.Failure("GitHub could not send \(url.path)")
        }
        return data
    }
}
