// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class GitHubReleaseServiceTests: XCTestCase, @unchecked Sendable {
    private final class ProtocolStub: URLProtocol {
        struct Response: Sendable {
            let data: Data
            var status = 200
        }

        static let responses = Mutex<[URL: Response]>([:])
        static let requests = Mutex<[URLRequest]>([])

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host?.hasSuffix(".example") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.requests.withLock { $0.append(request) }
            guard let url = request.url, let response = Self.responses.withLock({ $0[url] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testStableUsesLatestEndpointAndPreservesRequestHeaders() async throws {
        let service = service()
        defer { service.session.invalidateAndCancel() }
        try respond(to: "releases/latest", in: service, with: payload("v0.7.7"))

        let release = try await service.fetchLatestRelease(forCanary: false)

        XCTAssertEqual(release?.tagName, "v0.7.7")
        let requests = requests(for: service)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, service.repositoryURL.appendingPathComponent("releases/latest"))
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "User-Agent"), "OmniWM test")
    }

    func testReleaseArchiveComesOnlyFromItsOwnDigestedAppAsset() async throws {
        let service = service()
        defer { service.session.invalidateAndCancel() }
        let download = "https://github.com/OmniNull/OmniWM/releases/download/v0.7.7/"
        var json = payload("v0.7.7")
        json["assets"] = [
            [
                "name": "GhosttyKit.xcframework-v0.7.7.zip",
                "browser_download_url": download + "GhosttyKit.xcframework-v0.7.7.zip",
                "digest": "sha256:" + String(repeating: "b", count: 64)
            ],
            [
                "name": "OmniWM-v0.7.7.zip",
                "browser_download_url": download + "OmniWM-v0.7.7.zip",
                "digest": "sha256:" + String(repeating: "A", count: 64)
            ]
        ]
        try respond(to: "releases/latest", in: service, with: json)

        let release = try await service.fetchLatestRelease(forCanary: false)

        XCTAssertEqual(release?.archive?.url.absoluteString, download + "OmniWM-v0.7.7.zip")
        XCTAssertEqual(release?.archive?.sha256, String(repeating: "a", count: 64))
    }

    func testCanaryFindsNewestTagWithoutReleaseHistoryOrInstalledTag() async throws {
        let service = service()
        defer { service.session.invalidateAndCancel() }
        let newest = "canary-20261025-0437-40161156174-10"
        let older = "canary-20261025-0437-40161156174-9"
        try respond(to: "git/matching-refs/tags/canary-", in: service, with: [
            "refs/tags/\(older)", "refs/tags/v99.0.0", "refs/tags/canary-invalid",
            "refs/heads/canary-20261026-0437", "refs/tags/\(newest)", "refs/tags/canary-20261025-0437"
        ].map { ["ref": $0] })
        try respond(to: "releases/tags/\(newest)", in: service, with: payload(newest))

        let release = try await service.fetchLatestRelease(forCanary: true)

        XCTAssertEqual(release?.tagName, newest)
        XCTAssertEqual(requests(for: service).compactMap(\.url), [
            service.repositoryURL.appendingPathComponent("git/matching-refs/tags/canary-"),
            service.repositoryURL.appendingPathComponent("releases/tags/\(newest)")
        ])
    }

    func testCanarySkipsUnpublishedTagsDraftsAndOtherReleaseTypes() async throws {
        let service = service()
        defer { service.session.invalidateAndCancel() }
        let tags = (1 ... 5).reversed().map { "canary-20261025-0437-40161156174-\($0)" }
        try respond(to: "git/matching-refs/tags/canary-", in: service, with: tags.map { ["ref": "refs/tags/\($0)"] })
        try respond(to: "releases/tags/\(tags[0])", in: service, with: [:], status: 404)
        var draft = payload(tags[1])
        draft["draft"] = true
        try respond(to: "releases/tags/\(tags[1])", in: service, with: draft)
        try respond(to: "releases/tags/\(tags[2])", in: service, with: payload(tags[2], prerelease: false))
        var unpublished = payload(tags[3])
        unpublished["published_at"] = NSNull()
        try respond(to: "releases/tags/\(tags[3])", in: service, with: unpublished)
        try respond(to: "releases/tags/\(tags[4])", in: service, with: payload(tags[4]))

        let release = try await service.fetchLatestRelease(forCanary: true)

        XCTAssertEqual(release?.tagName, tags[4])
        XCTAssertEqual(requests(for: service).count, 6)
    }

    func testNoPublishedCanaryReturnsNoUpdate() async throws {
        let service = service()
        defer { service.session.invalidateAndCancel() }
        for references in [[], [["ref": "refs/tags/canary-20261025-0437"]]] {
            try respond(to: "git/matching-refs/tags/canary-", in: service, with: references)
            try respond(to: "releases/tags/canary-20261025-0437", in: service, with: [:], status: 404)
            let release = try await service.fetchLatestRelease(forCanary: true)
            XCTAssertNil(release)
        }
    }

    func testStableRejectsCanaryOrDraftPayload() async throws {
        let service = service()
        defer { service.session.invalidateAndCancel() }
        var draft = payload("v0.7.7")
        draft["draft"] = true
        for invalid in [payload("canary-20261025-0437"), payload("invalid"), draft] {
            try respond(to: "releases/latest", in: service, with: invalid)
            do {
                _ = try await service.fetchLatestRelease(forCanary: false)
                XCTFail("Expected an invalid tag error")
            } catch UpdateCoordinatorError.invalidTag {
            }
        }
    }

    func testHTTPFailureIsReportedInsteadOfFallingBack() async throws {
        let service = service()
        defer { service.session.invalidateAndCancel() }
        let tag = "canary-20261025-0437"
        try respond(to: "git/matching-refs/tags/canary-", in: service, with: [["ref": "refs/tags/\(tag)"]])
        try respond(to: "releases/latest", in: service, with: [:], status: 403)
        try respond(to: "releases/tags/\(tag)", in: service, with: [:], status: 403)
        for canary in [false, true] {
            do {
                _ = try await service.fetchLatestRelease(forCanary: canary)
                XCTFail("Expected an HTTP error")
            } catch UpdateCoordinatorError.badStatus(403) {
            }
        }
    }

    private func service() -> GitHubReleaseService {
        let base = URL(string: "https://\(UUID().uuidString.lowercased()).example/repos/OmniNull/OmniWM")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtocolStub.self]
        addTeardownBlock {
            ProtocolStub.responses.withLock { $0 = $0.filter { $0.key.host != base.host } }
            ProtocolStub.requests.withLock { $0.removeAll { $0.url?.host == base.host } }
        }
        return GitHubReleaseService(
            session: URLSession(configuration: configuration),
            repositoryURL: base, userAgent: "OmniWM test"
        )
    }

    private func requests(for service: GitHubReleaseService) -> [URLRequest] {
        ProtocolStub.requests.withLock { $0.filter { $0.url?.host == service.repositoryURL.host } }
    }

    private func respond(to path: String, in service: GitHubReleaseService, with json: Any, status: Int = 200) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        ProtocolStub.responses.withLock {
            $0[service.repositoryURL.appendingPathComponent(path)] = .init(data: data, status: status)
        }
    }

    private func payload(_ tag: String, prerelease: Bool? = nil) -> [String: Any] {
        [
            "tag_name": tag, "name": tag, "body": "Release notes",
            "html_url": "https://github.com/OmniNull/OmniWM/releases/tag/\(tag)",
            "published_at": "2026-10-25T04:37:16Z", "draft": false,
            "prerelease": prerelease ?? tag.hasPrefix("canary-")
        ]
    }
}
