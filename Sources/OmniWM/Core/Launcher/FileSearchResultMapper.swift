// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMLauncherSPI
import UniformTypeIdentifiers

struct FileSearchRecord: Sendable {
    let result: LauncherFileResult
    let candidate: SpotlightRanking.Candidate
}

enum FileSearchResultMapper {
    static let attributes = [
        "kMDItemPath",
        "kMDItemDisplayName",
        "kMDItemContentType",
        "kMDItemFSSize",
        "_kMDItemGroupId",
        "kMDItemContentModificationDate",
        "kMDItemContentCreationDate",
        "kMDItemLastUsedDate",
        "kMDItemKind",
        "kMDItemAuthors",
        "kMDItemTitle",
        "kMDItemDescription",
        "kMDItemFSName",
        "kMDItemIsScreenCapture",
        "_kMDItemRecentSpotlightEngagementDatesNonUnique",
        "_kMDItemRecentSpotlightEngagementQueriesNonUnique",
        "_kMDItemRecentOutOfSpotlightEngagementDates"
    ]
    static let valueListAttributes = attributes.filter { $0 != "kMDItemPath" }

    static func record(attributes: [String: Any]) -> FileSearchRecord? {
        guard let path = attributes["kMDItemPath"] as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        let displayName = attributes["kMDItemDisplayName"] as? String ?? url.lastPathComponent
        let contentType = attributes["kMDItemContentType"] as? String
        let modified = attributes["kMDItemContentModificationDate"] as? Date
        let created = attributes["kMDItemContentCreationDate"] as? Date
        let lastUsed = attributes["kMDItemLastUsedDate"] as? Date
        let result = LauncherFileResult(
            fileURL: url,
            displayName: displayName,
            contentTypeIdentifier: contentType,
            kind: attributes["kMDItemKind"] as? String,
            isDirectory: contentType.flatMap(UTType.init)?.conforms(to: .folder) == true,
            size: (attributes["kMDItemFSSize"] as? NSNumber)?.int64Value,
            createdAt: created,
            modifiedAt: modified,
            lastOpenedAt: lastUsed
        )
        let candidate = SpotlightRanking.Candidate(
            id: result.id,
            fields: SpotlightRanking.Fields(
                displayName: displayName,
                path: path,
                authors: firstString(attributes["kMDItemAuthors"]),
                title: attributes["kMDItemTitle"] as? String,
                description: attributes["kMDItemDescription"] as? String,
                fileSystemName: attributes["kMDItemFSName"] as? String,
                kind: result.kind,
                contentURL: url.absoluteString
            ),
            resultType: resultType(contentType: contentType, group: attributes["_kMDItemGroupId"] as? Int),
            engagement: SpotlightRanking.Engagement(
                inSpotlightDates: attributes["_kMDItemRecentSpotlightEngagementDatesNonUnique"] as? [Date] ?? [],
                inSpotlightQueries: attributes["_kMDItemRecentSpotlightEngagementQueriesNonUnique"] as? [String] ?? [],
                outOfSpotlightDates: attributes["_kMDItemRecentOutOfSpotlightEngagementDates"] as? [Date] ?? []
            ),
            lastUsedDate: lastUsed,
            modifiedDate: modified,
            createdDate: created
        )
        return FileSearchRecord(result: result, candidate: candidate)
    }

    static func rank(
        records: [FileSearchRecord],
        query: String,
        language: String,
        shortcutTarget: String? = nil,
        launchesByTarget: [String: [LauncherLaunch]] = [:],
        shouldCancel: () -> Bool = { false }
    ) -> [LauncherFileResult] {
        guard !shouldCancel() else { return [] }
        let evaluator = omniwm_spotlight_evaluator_create(query, language)
        defer { omniwm_spotlight_evaluator_release(evaluator) }
        guard let evaluator else {
            let shortcut = records.first { $0.result.id == shortcutTarget }?.result
            let others = records.filter { $0.result.id != shortcutTarget }.map(\.result)
            return Array(([shortcut].compactMap { $0 } + others).prefix(60))
        }
        let termCount = Int(omniwm_spotlight_query_term_count(evaluator))
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.result.id, $0.result) })
        let candidates = records.map { record in
            var candidate = record.candidate
            if let launches = launchesByTarget[record.result.id] {
                candidate.engagement.inSpotlightDates.append(contentsOf: launches.map(\.date))
                candidate.engagement.inSpotlightQueries.append(contentsOf: launches.map(\.foldedQuery))
            }
            return candidate
        }
        let ranked = SpotlightRanking.rank(
            query: query,
            termCount: termCount,
            candidates: candidates,
            shortcuts: shortcutTarget.map { [query.localizedLowercase: $0] } ?? [:],
            admitUnmatched: true,
            shouldCancel: shouldCancel,
            match: SpotlightRanking.shimMatcher(evaluator)
        )
        return Array(ranked.prefix(60).compactMap { byID[$0.id] })
    }

    static func fallbackQueryString(for text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map { token in
            let escaped = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
                of: "\"",
                with: "\\\""
            )
            return "(** = \"\(escaped)*\"cdw)"
        }.joined(separator: " && ")
    }

    static func types(for chip: LauncherChip?) -> [UTType] {
        switch chip?.id {
        case "folders": [.folder]
        case "pdfs": [.pdf]
        case "images": [.image]
        case "movies": [.movie]
        case "music": [.audio]
        case "presentations": [.presentation]
        case "spreadsheets": [.spreadsheet]
        case "documents": [.text, .compositeContent]
        case "developer": [.sourceCode]
        default: [.item]
        }
    }

    private static func firstString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return (value as? [String])?.first
    }

    private static func resultType(contentType: String?, group: Int?) -> SpotlightRanking.ResultType {
        if let contentType, let type = UTType(contentType), type.conforms(to: .folder) { return .folder }
        if group == 15 { return .developer }
        if group == 18 { return .other }
        return .typedFile
    }
}
