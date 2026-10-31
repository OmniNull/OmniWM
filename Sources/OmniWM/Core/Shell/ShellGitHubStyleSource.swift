// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

protocol ShellStyleSource: Sendable {
    var source: String { get }
    func styles() async throws -> [ShellStyleListing]
    func payload(for listing: ShellStyleListing) async throws -> ShellStylePayload
}

struct ShellGitHubStyleSource: ShellStyleSource {
    struct Repository: Hashable, Sendable, Identifiable {
        let owner: String
        let name: String

        var id: String {
            "\(owner)/\(name)"
        }

        var url: URL {
            URL(string: "https://github.com/\(id)")!
        }

        init?(source: String) {
            guard source.hasPrefix("github:") else { return nil }
            let tracking = source.dropFirst("github:".count)
            guard let separator = tracking.firstIndex(of: "@"), tracking.index(after: separator) < tracking.endIndex,
                  let repository = try? Self("https://github.com/\(tracking[..<separator])")
            else { return nil }
            self = repository
        }

        init(_ address: String) throws {
            guard let url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil
            else { throw Self.invalidURL }
            var path = url.path
            if path.hasSuffix("/") { path.removeLast() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].isEmpty else { throw Self.invalidURL }
            let owner = String(parts[1]).lowercased()
            var name = String(parts[2]).lowercased()
            if name.hasSuffix(".git") { name.removeLast(".git".count) }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
            guard !owner.isEmpty, !name.isEmpty, name != ".", name != "..",
                  owner.unicodeScalars.allSatisfy(allowed.contains),
                  name.unicodeScalars.allSatisfy(allowed.contains)
            else { throw Self.invalidURL }
            self.owner = owner
            self.name = name
        }

        private static var invalidURL: ShellStyleInstaller.Failure {
            ShellStyleInstaller.Failure("Enter the repository's main page: https://github.com/owner/repository")
        }
    }

    struct Browse: Sendable {
        let source: ShellGitHubStyleSource
        let listings: [ShellStyleListing]
        let problems: [String]
    }

    private struct Metadata: Decodable {
        let defaultBranch: String
    }

    private struct Commit: Decodable {
        let sha: String
        let commit: CommitInfo
    }

    private struct CommitInfo: Decodable {
        let tree: TreeReference
    }

    private struct TreeReference: Decodable {
        let sha: String
    }

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

    private struct GitHubError: Decodable {
        let message: String
    }

    private struct MissingManifest: Error {}

    static let folder = "styles"
    static let officialOwner = "OmniNull"
    static let officialRepository = "OmniWM"

    static var officialRepositoryName: String {
        "\(officialOwner)/\(officialRepository)"
    }

    let owner: String
    let repository: String
    let ref: String
    var session: URLSession
    private var trackingRef: String?
    private var rootTree: String?

    init(owner: String, repository: String, ref: String, session: URLSession = .shared) {
        self.owner = owner
        self.repository = repository
        self.ref = ref
        self.session = session
    }

    var repositoryName: String {
        "\(owner)/\(repository)"
    }

    var source: String {
        "github:\(repositoryName)@\(trackingRef ?? ref)"
    }

    static func official(bundle: Bundle = .main) -> Self? {
        guard let ref = bundle.canaryReleaseTag ?? bundle.appVersion.map({ "v" + $0 }) else { return nil }
        return Self(owner: officialOwner, repository: officialRepository, ref: ref)
    }

    static func browse(_ address: String, session: URLSession = .shared) async throws -> Browse {
        let repository = try Repository(address)
        let unresolved = Self(owner: repository.owner, repository: repository.name, ref: "", session: session)
        let metadata = try await unresolved.decode(Metadata.self, from: unresolved.api())
        let commit = try await unresolved.decode(
            Commit.self,
            from: unresolved.api("commits").appending(component: metadata.defaultBranch)
        )
        var source = Self(owner: repository.owner, repository: repository.name, ref: commit.sha, session: session)
        source.trackingRef = metadata.defaultBranch
        do {
            let data = try await source.fetch(
                source.raw.appending(path: ShellStyleManifest.fileName),
                missingAllowed: true
            )
            let manifest = try ShellStyleManifest.parse(data)
            guard ShellProfiles.isStyleName(manifest.name) else {
                throw ShellStyleInstaller.Failure("\(manifest.name) is not a valid style name")
            }
            source.rootTree = commit.commit.tree.sha
            return try Browse(source: source, listings: [ShellStyleListing(
                name: manifest.name, manifest: manifest, folder: source.raw, revision: source.rootTree
            )], problems: [])
        } catch is MissingManifest {
            return try await source.collection(toleratingInvalid: true)
        }
    }

    func styles() async throws -> [ShellStyleListing] {
        if let rootTree {
            let data = try await fetch(raw.appending(path: ShellStyleManifest.fileName))
            let manifest = try ShellStyleManifest.parse(data)
            return try [ShellStyleListing(name: manifest.name, manifest: manifest, folder: raw, revision: rootTree)]
        }
        return try await collection(toleratingInvalid: false).listings
    }

    func payload(for listing: ShellStyleListing) async throws -> ShellStylePayload {
        guard let revision = listing.revision
        else { throw ShellStyleInstaller.Failure("\(listing.name) has no revision") }
        let tree = try await decode(Tree.self, from: api("git/trees/\(revision)", .init(name: "recursive", value: "1")))
        guard !tree.truncated else { throw ShellStyleInstaller.Failure("GitHub listed only part of \(listing.name)") }
        var files: [ShellStyleFile] = []
        for item in tree.tree where Self.installs(item.path) {
            if item.type == "tree" { continue }
            guard item.type == "blob", ["100644", "100755"].contains(item.mode) else {
                throw ShellStyleInstaller.Failure("\(listing.name)/\(item.path) is not a regular file")
            }
            let data = try await fetch(folder(of: listing.name).appending(path: item.path))
            files.append(ShellStyleFile(path: item.path, data: data, executable: item.mode == "100755"))
        }
        return ShellStylePayload(name: listing.name, source: source, files: files.sorted { $0.path < $1.path })
    }

    private func collection(toleratingInvalid: Bool) async throws -> Browse {
        let entries: [Entry]
        do {
            entries = try await decode(
                [Entry].self, from: api("contents/\(Self.folder)", .init(name: "ref", value: ref)),
                missingAllowed: toleratingInvalid
            )
        } catch is MissingManifest {
            throw ShellStyleInstaller.Failure("\(repositoryName) has no style.toml or styles/<name>/style.toml")
        }
        var listings: [ShellStyleListing] = []
        var problems: [String] = []
        for entry in entries where entry.type == "dir" {
            do {
                guard ShellProfiles.isStyleName(entry.name) else {
                    if !toleratingInvalid { continue }
                    throw ShellStyleInstaller.Failure("not a valid style folder name")
                }
                let folder = folder(of: entry.name)
                let data = try await fetch(folder.appending(path: ShellStyleManifest.fileName))
                listings.append(try ShellStyleListing(
                    name: entry.name, manifest: ShellStyleManifest.parse(data), folder: folder, revision: entry.sha
                ))
            } catch {
                if !toleratingInvalid || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                problems.append("\(entry.name): \(error.localizedDescription)")
            }
        }
        if toleratingInvalid, listings.isEmpty, problems.isEmpty {
            problems.append("\(repositoryName) has no installable styles.")
        }
        return Browse(
            source: self,
            listings: listings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            problems: problems
        )
    }

    private static func installs(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.first.map(String.init) != ShellStyleRepository.previewsFolder
            && !components.contains { $0.hasPrefix(".") }
    }

    private func api(_ path: String = "", _ query: URLQueryItem? = nil) -> URL {
        let base = URL(string: "https://api.github.com/repos/\(repositoryName)")!
        let url = path.isEmpty ? base : base.appending(path: path)
        return query.map { url.appending(queryItems: [$0]) } ?? url
    }

    private var raw: URL {
        URL(string: "https://raw.githubusercontent.com/\(repositoryName)/\(ref)")!
    }

    private func folder(of style: String) -> URL {
        rootTree == nil ? raw.appending(path: "\(Self.folder)/\(style)") : raw
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type, from url: URL, missingAllowed: Bool = false
    ) async throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: await fetch(url, missingAllowed: missingAllowed))
    }

    private func fetch(_ url: URL, missingAllowed: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OmniWM", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if missingAllowed, status == 404 { throw MissingManifest() }
        guard let status, (200 ... 299).contains(status) else {
            let detail = (try? JSONDecoder().decode(GitHubError.self, from: data))?.message
            throw ShellStyleInstaller.Failure(detail ?? "GitHub could not send \(url.path)")
        }
        return data
    }
}
