// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct GitHubReleaseService: GitHubReleaseFetching, Sendable {
    var session: URLSession = .shared
    var repositoryURL = URL(string: "https://api.github.com/repos/OmniNull/OmniWM")!
    var userAgent = "OmniWM"

    func fetchLatestRelease(forCanary: Bool) async throws -> GitHubRelease? {
        if !forCanary {
            let release = try await fetchRelease(at: repositoryURL.appendingPathComponent("releases/latest"))
            guard !release.isDraft, !release.isPrerelease, release.version != nil else {
                throw UpdateCoordinatorError.invalidTag
            }
            return release
        }

        let data = try await fetch(repositoryURL.appendingPathComponent("git/matching-refs/tags/canary-"))
        let references = try JSONDecoder().decode([GitHubReference].self, from: data)
        let tags = references.compactMap { reference -> String? in
            let prefix = "refs/tags/"
            guard reference.ref.hasPrefix(prefix) else { return nil }
            let tag = String(reference.ref.dropFirst(prefix.count))
            return GitHubRelease.isCanaryTag(tag) ? tag : nil
        }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }

        for tag in tags {
            do {
                let release = try await fetchRelease(at: repositoryURL.appendingPathComponent("releases/tags/\(tag)"))
                if release.tagName == tag, release.isPublishedCanary {
                    return release
                }
            } catch UpdateCoordinatorError.badStatus(404) {
                continue
            }
        }
        return nil
    }

    private func fetchRelease(at url: URL) async throws -> GitHubRelease {
        let data = try await fetch(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubReleasePayload.self, from: data).release
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCoordinatorError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw UpdateCoordinatorError.badStatus(httpResponse.statusCode)
        }
        return data
    }
}

private struct GitHubReference: Decodable {
    let ref: String
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let prerelease: Bool
    let draft: Bool
    let assets: [GitHubReleaseAsset]?

    var release: GitHubRelease {
        GitHubRelease(
            tagName: tagName,
            name: name,
            body: body ?? "",
            releasePageURL: htmlURL,
            publishedAt: publishedAt,
            isPrerelease: prerelease,
            isDraft: draft,
            archive: assets?.lazy.compactMap { [tagName] asset in
                ReleaseArchive(name: asset.name, url: asset.browserDownloadURL, digest: asset.digest, tag: tagName)
            }.first
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case draft
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}
