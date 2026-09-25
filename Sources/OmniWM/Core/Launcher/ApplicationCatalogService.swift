// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreServices
import Foundation
import OmniWMLauncherSPI
import Synchronization

@MainActor
final class ApplicationCatalogService {
    static let shared = ApplicationCatalogService()

    private(set) var hasLoadedCatalog = false
    var onCatalogChanged: (@MainActor () -> Void)?
    private(set) var chips: [LauncherChip] = []

    private var sources: [ApplicationCatalogSource]?
    private var entries: [ApplicationCatalogEntry] = []
    private var isRefreshing = false
    private var fingerprint: ApplicationCatalogFingerprint?
    private nonisolated let buildQueue = DispatchQueue(
        label: "com.barut.OmniWM.launcher.applications.catalog",
        qos: .userInitiated
    )
    private nonisolated let rankingQueue = DispatchQueue(
        label: "com.barut.OmniWM.launcher.applications.ranking",
        qos: .userInitiated
    )
    private nonisolated let rankingSerial = Atomic<UInt64>(0)

    private nonisolated static let metadataAttributes = [
        "kMDItemPath",
        "kMDItemAlternateNames",
        "kMDItemAppStoreCategoryType",
        kMDItemLastUsedDate as String,
        "kMDItemUseCount",
        "_kMDItemRecentSpotlightEngagementDatesNonUnique",
        "_kMDItemRecentSpotlightEngagementQueriesNonUnique",
        "_kMDItemRecentOutOfSpotlightEngagementDates"
    ]

    func refreshIfNeeded(refreshMetadata: Bool = false) {
        guard !isRefreshing else { return }
        let currentFingerprint = Self.databaseFingerprint()
        let isCurrent = hasLoadedCatalog && (currentFingerprint == nil || currentFingerprint == fingerprint)
        guard !isCurrent || refreshMetadata else { return }
        isRefreshing = true
        let reusableSources = isCurrent ? sources : nil
        buildQueue.async { [weak self] in
            let metadata = Self.applicationMetadata()
            let sources = reusableSources ?? Self.catalogSources(metadata: metadata)
            let entries = sources.map { Self.buildEntries($0, metadata: metadata) }
            Task { @MainActor [weak self] in
                self?.finishRefresh(
                    sources: sources,
                    entries: entries,
                    rebuilt: reusableSources == nil,
                    fingerprint: currentFingerprint
                )
            }
        }
    }

    func browse(
        chip: LauncherChip?,
        hiddenSuggestions: Set<String> = [],
        launchesFor: (String) -> [LauncherLaunch] = { _ in [] }
    ) -> [LauncherSection<LauncherApplicationResult>] {
        guard hasLoadedCatalog else { return [] }
        if case let .applicationCategory(category)? = chip?.filter {
            let filtered = entries.filter { $0.category == category }.map(\.result)
            return filtered.isEmpty ? [] : [
                LauncherSection(
                    id: .category(category),
                    title: entries.first { $0.category == category }?.result.categoryName ?? String(localized: "Other"),
                    items: filtered
                )
            ]
        }

        let suggestions = Array(
            entries.compactMap { entry -> (entry: ApplicationCatalogEntry, date: Date?)? in
                guard !hiddenSuggestions.contains(entry.result.id) else { return nil }
                let ownDate = launchesFor(entry.result.id).map(\.date).max()
                let date = [entry.lastUsedDate, ownDate].compactMap { $0 }.max()
                guard date != nil || entry.useCount > 0 else { return nil }
                return (entry, date)
            }
            .sorted {
                if $0.date != $1.date {
                    return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
                }
                return $0.entry.useCount > $1.entry.useCount
            }
            .prefix(5)
            .map(\.entry.result)
        )
        var sections: [LauncherSection<LauncherApplicationResult>] = []
        if !suggestions.isEmpty {
            sections.append(LauncherSection(
                id: .suggestions,
                title: String(localized: "Suggestions"),
                items: suggestions
            ))
        }
        let classified = entries.filter { $0.category != nil }.map(\.result)
        if !classified.isEmpty {
            sections.append(LauncherSection(id: .all, title: String(localized: "Applications"), items: classified))
        }
        let other = entries.filter { $0.category == nil }.map(\.result)
        if !other.isEmpty {
            sections.append(LauncherSection(id: .other, title: String(localized: "Other"), items: other))
        }
        return sections
    }

    func rank(
        query: String,
        chip: LauncherChip?,
        generation: Int,
        language: String,
        shortcutTarget: String? = nil,
        launchesFor: (String) -> [LauncherLaunch] = { _ in [] },
        publish: @escaping @MainActor (Int, [LauncherSection<LauncherApplicationResult>]) -> Void
    ) {
        let serial = rankingSerial.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        let filtered: [ApplicationCatalogEntry]
        if case let .applicationCategory(category)? = chip?.filter {
            filtered = entries.filter { $0.category == category }
        } else {
            filtered = entries
        }
        let candidates = filtered.map { entry in
            var candidate = entry.candidate
            let launches = launchesFor(entry.result.id)
            candidate.engagement.inSpotlightDates.append(contentsOf: launches.map(\.date))
            candidate.engagement.inSpotlightQueries.append(contentsOf: launches.map(\.foldedQuery))
            return RankingInput(result: entry.result, candidate: candidate)
        }
        rankingQueue.async { [self] in
            let isCurrent: @Sendable () -> Bool = { self.rankingSerial.load(ordering: .acquiring) == serial }
            guard isCurrent() else { return }
            let results = Self.rank(
                candidates,
                query: query,
                language: language,
                shortcutTarget: shortcutTarget,
                shouldCancel: { !isCurrent() }
            )
            guard isCurrent() else { return }
            Task { @MainActor in
                guard isCurrent() else { return }
                publish(generation, results.isEmpty ? [] : [
                    LauncherSection(id: .results, title: String(localized: "Results"), items: results)
                ])
            }
        }
    }

    func cancelRanking() {
        _ = rankingSerial.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }

    private func finishRefresh(
        sources: [ApplicationCatalogSource]?,
        entries next: [ApplicationCatalogEntry]?,
        rebuilt: Bool,
        fingerprint: ApplicationCatalogFingerprint?
    ) {
        isRefreshing = false
        hasLoadedCatalog = true
        guard let sources, let next else {
            onCatalogChanged?()
            return
        }
        self.sources = sources
        self.fingerprint = fingerprint
        entries = next.sorted {
            $0.result.displayName.localizedStandardCompare($1.result.displayName) == .orderedAscending
        }
        if rebuilt {
            LauncherIconStore.shared.clear()
            chips = Self.categoryChips(for: entries)
        }
        onCatalogChanged?()
    }

    private static func categoryChips(for entries: [ApplicationCatalogEntry]) -> [LauncherChip] {
        let categories = Dictionary(grouping: entries.compactMap(\.category), by: { $0 })
        var categoryNames: [String: String] = [:]
        for entry in entries {
            if let category = entry.category, let name = entry.result.categoryName {
                categoryNames[category] = name
            }
        }
        return categories.keys.sorted {
            let leftCount = categories[$0]?.count ?? 0
            let rightCount = categories[$1]?.count ?? 0
            if leftCount != rightCount {
                return leftCount > rightCount
            }
            return (categoryNames[$0] ?? "").localizedStandardCompare(categoryNames[$1] ?? "") == .orderedAscending
        }.map {
            LauncherChip(id: $0, title: categoryNames[$0] ?? "", filter: .applicationCategory($0))
        }
    }
}

extension ApplicationCatalogService {
    private nonisolated static func catalogSources(
        metadata: [String: ApplicationCatalogMetadata]
    ) -> [ApplicationCatalogSource]? {
        guard let records = omniwm_launcher_copy_app_records() else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var identifiers: Set<String> = []
        var paths: Set<String> = []
        var sources: [ApplicationCatalogSource] = []
        for record in records {
            let path = URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path
            guard ApplicationCatalogFilter.isCatalogPath(path, home: home),
                  identifiers.insert(record.bundleIdentifier).inserted
            else {
                continue
            }
            paths.insert(path)
            sources.append(ApplicationCatalogSource(
                path: path,
                bundleIdentifier: record.bundleIdentifier,
                displayName: record.displayName,
                alternateNames: record.alternateNames,
                lsCategory: record.category
            ).categorized(fallback: metadata[path]?.category))
        }
        var scannedPaths = ApplicationCatalogFilter.scannedBundlePaths(home: home)
        if !paths.contains(ApplicationCatalogFilter.finderPath) {
            scannedPaths.append(ApplicationCatalogFilter.finderPath)
        }
        for path in scannedPaths where !paths.contains(path) {
            guard let identifier = Bundle(path: path)?.bundleIdentifier,
                  identifiers.insert(identifier).inserted
            else {
                continue
            }
            paths.insert(path)
            sources.append(ApplicationCatalogSource(
                path: path,
                bundleIdentifier: identifier,
                displayName: FileManager.default.displayName(atPath: path),
                alternateNames: [],
                lsCategory: nil
            ).categorized(fallback: metadata[path]?.category))
        }
        return sources
    }

    private nonisolated static func buildEntries(
        _ sources: [ApplicationCatalogSource],
        metadata: [String: ApplicationCatalogMetadata]
    ) -> [ApplicationCatalogEntry] {
        sources.map { source in
            let values = metadata[source.path] ?? ApplicationCatalogMetadata()
            let url = URL(fileURLWithPath: source.path)
            var seenNames: Set<String> = [source.displayName]
            let alternateNames = (values.alternateNames + source.alternateNames + [
                url.deletingPathExtension().lastPathComponent
            ]).filter { seenNames.insert($0).inserted }
            let identifier = source.bundleIdentifier.split(separator: ".").last.map(String.init)?.lowercased()
            let result = LauncherApplicationResult(
                bundleURL: url,
                bundleIdentifier: source.bundleIdentifier,
                displayName: source.displayName,
                categoryName: source.categoryName
            )
            let candidate = SpotlightRanking.Candidate(
                id: result.id,
                fields: SpotlightRanking.Fields(
                    displayName: source.displayName,
                    alternateNames: alternateNames,
                    foldedAlternateNames: alternateNames.map(SpotlightRanking.fold),
                    identifier: identifier.flatMap { $0.count >= 3 ? $0 : nil },
                    initials: initials(source.displayName)
                ),
                resultType: .application,
                engagement: values.engagement,
                lastUsedDate: values.lastUsedDate
            )
            return ApplicationCatalogEntry(
                result: result,
                category: source.category,
                candidate: candidate,
                lastUsedDate: values.lastUsedDate,
                useCount: values.engagement.useCount
            )
        }
    }

    private nonisolated static func applicationMetadata() -> [String: ApplicationCatalogMetadata] {
        let valueList = metadataAttributes.filter { $0 != "kMDItemPath" }
        guard let query = MDQueryCreate(
            nil,
            "kMDItemContentTypeTree == \"com.apple.application\"" as CFString,
            valueList as CFArray,
            nil
        ) else {
            return [:]
        }
        MDQuerySetSearchScope(query, [kMDQueryScopeComputer] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [:] }
        defer { MDQueryStop(query) }
        let attributes = metadataAttributes as CFArray
        var metadata: [String: ApplicationCatalogMetadata] = [:]
        for index in 0 ..< MDQueryGetResultCount(query) {
            guard let raw = omniwm_mdquery_copy_result_attributes(query, index, attributes),
                  let values = raw as? [String: Any],
                  let path = values["kMDItemPath"] as? String
            else {
                continue
            }
            metadata[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = ApplicationCatalogMetadata(
                values: values
            )
        }
        return metadata
    }

    private nonisolated static func rank(
        _ inputs: [RankingInput],
        query: String,
        language: String,
        shortcutTarget: String?,
        shouldCancel: () -> Bool
    ) -> [LauncherApplicationResult] {
        let evaluator = omniwm_spotlight_evaluator_create(query, language)
        defer { omniwm_spotlight_evaluator_release(evaluator) }
        guard let evaluator else {
            return fallbackRank(inputs, query: query, shortcutTarget: shortcutTarget, shouldCancel: shouldCancel)
        }
        let termCount = Int(omniwm_spotlight_query_term_count(evaluator))
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.result.id, $0.result) })
        let shortcuts = shortcutTarget.map { [query.localizedLowercase: $0] } ?? [:]
        let ranked = SpotlightRanking.rank(
            query: query,
            termCount: termCount,
            candidates: inputs.map(\.candidate),
            shortcuts: shortcuts,
            shouldCancel: shouldCancel,
            match: SpotlightRanking.shimMatcher(evaluator)
        )
        return Array(ranked.prefix(60).compactMap { byID[$0.id] })
    }

    private nonisolated static func fallbackRank(
        _ inputs: [RankingInput],
        query: String,
        shortcutTarget: String?,
        shouldCancel: () -> Bool
    ) -> [LauncherApplicationResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let shortcut = inputs.first { $0.result.id == shortcutTarget }?.result
        var matches: [LauncherApplicationResult] = []
        for input in inputs {
            if shouldCancel() { return [] }
            guard input.result.id != shortcutTarget else { continue }
            let fields = [input.candidate.fields.displayName] + input.candidate.fields.alternateNames +
                [input.candidate.fields.identifier].compactMap { $0 }
            if terms.allSatisfy({ term in fields.contains { $0.localizedStandardContains(term) } }) {
                matches.append(input.result)
            }
        }
        return Array(([shortcut].compactMap { $0 } + matches).prefix(60))
    }

    private nonisolated static func initials(_ name: String) -> String {
        String(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap(\.first))
    }

    private nonisolated static func databaseFingerprint() -> ApplicationCatalogFingerprint? {
        var sequence: UInt64 = 0
        guard let uuid = omniwm_launcher_database_fingerprint(&sequence) else { return nil }
        return ApplicationCatalogFingerprint(uuid: uuid, sequence: sequence)
    }
}

private struct ApplicationCatalogFingerprint: Equatable, Sendable {
    let uuid: String
    let sequence: UInt64
}

private struct ApplicationCatalogSource: Sendable {
    let path: String
    let bundleIdentifier: String
    let displayName: String
    let alternateNames: [String]
    let lsCategory: String?
    var category: String?
    var categoryName: String?

    func categorized(fallback: String?) -> Self {
        var source = self
        let mapped = omniwm_launcher_app_category(bundleIdentifier, lsCategory ?? fallback)
        source.categoryName = mapped.flatMap { omniwm_launcher_category_name($0) }
        source.category = source.categoryName == nil ? nil : mapped
        return source
    }
}

private struct ApplicationCatalogMetadata: Sendable {
    var alternateNames: [String] = []
    var category: String?
    var lastUsedDate: Date?
    var engagement = SpotlightRanking.Engagement()

    init() {}

    init(values: [String: Any]) {
        alternateNames = (values["kMDItemAlternateNames"] as? [String] ?? []).filter { !$0.isEmpty }
        category = values["kMDItemAppStoreCategoryType"] as? String
        lastUsedDate = values[kMDItemLastUsedDate as String] as? Date
        engagement = SpotlightRanking.Engagement(
            inSpotlightDates: values["_kMDItemRecentSpotlightEngagementDatesNonUnique"] as? [Date] ?? [],
            inSpotlightQueries: values["_kMDItemRecentSpotlightEngagementQueriesNonUnique"] as? [String] ?? [],
            outOfSpotlightDates: values["_kMDItemRecentOutOfSpotlightEngagementDates"] as? [Date] ?? [],
            useCount: values["kMDItemUseCount"] as? Int ?? 0
        )
    }
}

private struct ApplicationCatalogEntry: Sendable {
    let result: LauncherApplicationResult
    let category: String?
    let candidate: SpotlightRanking.Candidate
    let lastUsedDate: Date?
    let useCount: Int
}

private struct RankingInput: Sendable {
    let result: LauncherApplicationResult
    let candidate: SpotlightRanking.Candidate
}
