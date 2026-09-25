// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreServices
import Foundation
import OmniWMLauncherSPI
import Synchronization
import UniformTypeIdentifiers

struct FileSearchPersonalization: Sendable {
    let language: String
    let shortcutTarget: String?
    let launchesByTarget: [String: [LauncherLaunch]]
}

actor FileSearchEngine {
    static let shared = FileSearchEngine()

    nonisolated let ioQueue = DispatchSerialQueue(
        label: "com.barut.OmniWM.launcher.files",
        qos: .userInteractive
    )

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioQueue.asUnownedSerialExecutor()
    }

    private nonisolated let requestSerial = Atomic<UInt64>(0)
    private nonisolated let scoringQueue = DispatchQueue(
        label: "com.barut.OmniWM.launcher.files.scoring",
        qos: .userInitiated
    )
    private nonisolated let suggestionsQueue = DispatchQueue(
        label: "com.barut.OmniWM.launcher.files.suggestions",
        qos: .utility
    )

    static let chips: [LauncherChip] = [
        LauncherChip(
            id: "folders",
            title: String(localized: "Folders"),
            filter: .filePredicate("kMDItemContentTypeTree = public.folder")
        ),
        LauncherChip(
            id: "pdfs",
            title: String(localized: "PDFs"),
            filter: .filePredicate("kMDItemContentTypeTree = com.adobe.pdf")
        ),
        LauncherChip(
            id: "images",
            title: String(localized: "Images"),
            filter: .filePredicate("kMDItemContentTypeTree = public.image")
        ),
        LauncherChip(
            id: "movies",
            title: String(localized: "Movies"),
            filter: .filePredicate("kMDItemContentTypeTree = public.movie")
        ),
        LauncherChip(
            id: "music",
            title: String(localized: "Music"),
            filter: .filePredicate("kMDItemContentTypeTree = public.audio")
        ),
        LauncherChip(
            id: "presentations",
            title: String(localized: "Presentations"),
            filter: .filePredicate("kMDItemContentTypeTree = public.presentation")
        ),
        LauncherChip(
            id: "spreadsheets",
            title: String(localized: "Spreadsheets"),
            filter: .filePredicate("kMDItemContentTypeTree = public.spreadsheet")
        ),
        LauncherChip(
            id: "documents",
            title: String(localized: "Documents"),
            filter: .filePredicate(
                "(kMDItemContentTypeTree = public.text) || (kMDItemContentTypeTree = public.composite-content)"
            )
        ),
        LauncherChip(
            id: "developer",
            title: String(localized: "Developer"),
            filter: .filePredicate("kMDItemContentTypeTree = public.source-code")
        ),
        LauncherChip(
            id: "screenshots",
            title: String(localized: "Screenshots"),
            filter: .filePredicate("kMDItemIsScreenCapture = 1")
        )
    ]

    private typealias Publication = @MainActor @Sendable (Int, [LauncherSection<LauncherFileResult>]) -> Void

    private struct Submission: Sendable {
        let text: String
        let chip: LauncherChip?
        let generation: Int
        let serial: UInt64
        let personalization: FileSearchPersonalization
    }

    private var query: MDQuery?
    private var notificationTarget: FileQueryNotificationTarget?
    private var activeSerial: UInt64 = 0
    private var activeGeneration = 0
    private var activeText = ""
    private var activeChip: LauncherChip?
    private var activePersonalization: FileSearchPersonalization?
    private var publish: Publication?
    private var suggestions: [LauncherFileResult]?
    private var recents: [LauncherFileResult]?
    private var suggestionCache: (modified: Date, results: [LauncherFileResult])?

    nonisolated func submit(
        query text: String,
        chip: LauncherChip?,
        generation: Int,
        personalization: FileSearchPersonalization,
        publish: @escaping @MainActor @Sendable (Int, [LauncherSection<LauncherFileResult>]) -> Void
    ) {
        let serial = requestSerial.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        let submission = Submission(
            text: text,
            chip: chip,
            generation: generation,
            serial: serial,
            personalization: personalization
        )
        ioQueue.async { [self] in
            assumeIsolated { isolated in
                isolated.submitOnQueue(submission, publish: publish)
            }
        }
    }

    nonisolated func stop() {
        _ = requestSerial.wrappingAdd(1, ordering: .acquiringAndReleasing)
        ioQueue.async { [self] in
            assumeIsolated { isolated in isolated.stopOnQueue() }
        }
    }

    private func submitOnQueue(_ submission: Submission, publish: @escaping Publication) {
        let (text, chip, generation, serial, personalization) = (
            submission.text,
            submission.chip,
            submission.generation,
            submission.serial,
            submission.personalization
        )
        guard requestSerial.load(ordering: .acquiring) == serial else { return }
        stopOnQueue()
        activeSerial = serial
        activeGeneration = generation
        activeText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activeChip = chip
        activePersonalization = personalization
        self.publish = publish

        if activeText.isEmpty {
            loadSuggestions(generation: generation, serial: serial, chip: chip)
        }

        guard let queryString = queryString(for: activeText, chip: chip),
              let newQuery = createQuery(queryString, isRecents: activeText.isEmpty)
        else {
            publishEmptyQueryResults(generation: generation)
            return
        }

        query = newQuery
        let target = FileQueryNotificationTarget { [weak self] in
            self?.assumeIsolated { isolated in isolated.queryDidFinish(generation: generation, serial: serial) }
        }
        notificationTarget = target
        NotificationCenter.default.addObserver(
            target,
            selector: #selector(FileQueryNotificationTarget.queryDidFinish(_:)),
            name: kMDQueryDidFinishNotification as Notification.Name,
            object: newQuery
        )
        guard MDQueryExecute(newQuery, 0) else {
            stopQuery()
            publishEmptyQueryResults(generation: generation)
            return
        }
    }

    private func publishEmptyQueryResults(generation: Int) {
        if activeText.isEmpty {
            recents = []
            publishBrowseIfReady(generation: generation)
        } else {
            publishPage(generation: generation, sections: [])
        }
    }

    private func stopOnQueue() {
        publish = nil
        suggestions = nil
        recents = nil
        activeGeneration &+= 1
        activeSerial = 0
        activePersonalization = nil
        stopQuery()
    }

    private func stopQuery() {
        guard let query else { return }
        self.query = nil
        if let notificationTarget {
            NotificationCenter.default.removeObserver(
                notificationTarget,
                name: kMDQueryDidFinishNotification as Notification.Name,
                object: query
            )
            self.notificationTarget = nil
        }
        MDQueryStop(query)
    }

    private func queryDidFinish(generation: Int, serial: UInt64) {
        guard generation == activeGeneration,
              serial == activeSerial,
              requestSerial.load(ordering: .acquiring) == serial,
              let query
        else {
            return
        }
        let text = activeText
        guard var records = collectResults(from: query, serial: serial) else {
            stopQuery()
            return
        }
        stopQuery()

        if text.isEmpty {
            recents = records.map(\.result).sorted {
                ($0.lastOpenedAt ?? $0.modifiedAt ?? $0.createdAt ?? .distantPast) >
                    ($1.lastOpenedAt ?? $1.modifiedAt ?? $1.createdAt ?? .distantPast)
            }
            publishBrowseIfReady(generation: generation)
            return
        }

        let personalization = activePersonalization
        let shortcutTarget = personalization?.shortcutTarget
        if let shortcutTarget,
           !records.contains(where: { $0.result.id == shortcutTarget }),
           let shortcut = shortcutRecord(path: shortcutTarget, chip: activeChip)
        {
            records.append(shortcut)
        }

        let language = personalization?.language ?? ""
        scoringQueue.async { [self, records] in
            let isCurrent: @Sendable () -> Bool = { self.requestSerial.load(ordering: .acquiring) == serial }
            guard isCurrent() else { return }
            let ranked = FileSearchResultMapper.rank(
                records: records,
                query: text,
                language: language,
                shortcutTarget: shortcutTarget,
                launchesByTarget: personalization?.launchesByTarget ?? [:],
                shouldCancel: { !isCurrent() }
            )
            ioQueue.async { [self] in
                assumeIsolated { isolated in
                    isolated.publishRanked(generation: generation, serial: serial, ranked: ranked)
                }
            }
        }
    }

    private func publishRanked(generation: Int, serial: UInt64, ranked: [LauncherFileResult]) {
        guard generation == activeGeneration, serial == activeSerial else { return }
        publishPage(
            generation: generation,
            sections: ranked.isEmpty ? [] : [
                LauncherSection(id: .results, title: String(localized: "Results"), items: ranked)
            ]
        )
    }

    private func publishBrowseIfReady(generation: Int) {
        guard activeGeneration == generation,
              let suggestions,
              let recents
        else {
            return
        }
        let suggestedIDs = Set(suggestions.map(\.id))
        let remainingRecents = recents.filter { !suggestedIDs.contains($0.id) }
        var sections: [LauncherSection<LauncherFileResult>] = []
        if !suggestions.isEmpty {
            sections.append(LauncherSection(
                id: .suggestions,
                title: String(localized: "Suggestions"),
                items: suggestions
            ))
        }
        if !remainingRecents.isEmpty {
            sections.append(LauncherSection(id: .recents, title: String(localized: "Recents"), items: remainingRecents))
        }
        publishPage(generation: generation, sections: sections)
    }

    private func publishPage(generation: Int, sections: [LauncherSection<LauncherFileResult>]) {
        guard let publish,
              generation == activeGeneration,
              requestSerial.load(ordering: .acquiring) == activeSerial
        else {
            return
        }
        Task { @MainActor in publish(generation, sections) }
    }
}

extension FileSearchEngine {
    private func loadSuggestions(generation: Int, serial: UInt64, chip: LauncherChip?) {
        if chip?.id == "screenshots" {
            suggestions = []
            publishBrowseIfReady(generation: generation)
            return
        }
        let acceptedTypes = FileSearchResultMapper.types(for: chip)
        let modified = FileSuggestionsReader.modificationDate()
        if let cache = suggestionCache, cache.modified == modified {
            suggestions = FileSuggestionsReader.filter(cache.results, acceptedTypes: acceptedTypes)
            publishBrowseIfReady(generation: generation)
            return
        }
        suggestionsQueue.async { [self] in
            let results = FileSuggestionsReader.read(acceptedTypes: [], limit: 32)
            ioQueue.async { [self] in
                assumeIsolated { isolated in
                    if let modified {
                        isolated.suggestionCache = (modified, results)
                    }
                    guard generation == isolated.activeGeneration, serial == isolated.activeSerial else { return }
                    isolated.suggestions = FileSuggestionsReader.filter(results, acceptedTypes: acceptedTypes)
                    isolated.publishBrowseIfReady(generation: generation)
                }
            }
        }
    }

    private func shortcutRecord(path: String, chip: LauncherChip?) -> FileSearchRecord? {
        guard FileManager.default.fileExists(atPath: path),
              !path.lowercased().hasSuffix(".app"),
              let item = MDItemCreate(nil, path as CFString),
              let attributes = MDItemCopyAttributes(
                  item,
                  FileSearchResultMapper.attributes as CFArray
              ) as? [String: Any],
              let record = FileSearchResultMapper.record(attributes: attributes),
              let contentType = record.result.contentTypeIdentifier,
              let type = UTType(contentType),
              !type.conforms(to: .application)
        else {
            return nil
        }
        if chip?.id == "screenshots" {
            return (attributes["kMDItemIsScreenCapture"] as? NSNumber)?.boolValue == true ? record : nil
        }
        return FileSearchResultMapper.types(for: chip).contains { type.conforms(to: $0) } ? record : nil
    }

    private func queryString(for text: String, chip: LauncherChip?) -> String? {
        let filter: String?
        if case let .filePredicate(predicate)? = chip?.filter {
            filter = predicate
        } else {
            filter = nil
        }

        if text.isEmpty {
            let types = filter ?? "(kMDItemContentTypeTree = public.content) || (kMDItemContentTypeTree = \"com.microsoft.*\"cdw) || (kMDItemContentTypeTree = public.archive)"
            return "(kMDItemLastUsedDate = \"*\") && (\(types))"
        }

        let generated = omniwm_mdquery_create_query_string(text as CFString).map { $0 as String }
        let search = generated ?? FileSearchResultMapper.fallbackQueryString(for: text)
        guard !search.isEmpty else { return nil }
        var terms = ["(\(search))", "(kMDItemContentTypeTree != com.apple.application)"]
        if let filter { terms.append("(\(filter))") }
        return terms.joined(separator: " && ")
    }

    private func createQuery(_ expression: String, isRecents: Bool) -> MDQuery? {
        let sortAttribute: CFString = if isRecents {
            kMDItemLastUsedDate
        } else {
            omniwm_mdquery_menu_relevance_attribute() ?? kMDItemLastUsedDate
        }
        guard let query = MDQueryCreate(
            nil,
            expression as CFString,
            FileSearchResultMapper.valueListAttributes as CFArray,
            [sortAttribute] as CFArray
        ) else {
            return nil
        }
        _ = MDQuerySetSortOptionFlagsForAttribute(query, sortAttribute, 1)
        MDQuerySetDispatchQueue(query, ioQueue)
        if isRecents {
            let scope = omniwm_mdquery_scope_my_files() ?? kMDQueryScopeHome
            MDQuerySetSearchScope(query, [scope] as CFArray, 0)
            _ = omniwm_mdquery_set_matches_only_finder_files(query, true)
        } else {
            MDQuerySetSearchScope(query, [kMDQueryScopeComputer] as CFArray, 0)
        }
        _ = omniwm_mdquery_set_matches_support_files(query, false)
        MDQuerySetMaxCount(query, isRecents ? 100 : 200)
        return query
    }

    private func collectResults(from query: MDQuery, serial: UInt64) -> [FileSearchRecord]? {
        let count = min(MDQueryGetResultCount(query), 200)
        let names = FileSearchResultMapper.attributes as CFArray
        var results: [FileSearchRecord] = []
        var seenPaths = Set<String>()
        results.reserveCapacity(count)
        for index in 0 ..< count {
            if index.isMultiple(of: 8), requestSerial.load(ordering: .acquiring) != serial {
                return nil
            }
            guard let raw = omniwm_mdquery_copy_result_attributes(query, index, names),
                  let attributes = raw as? [String: Any],
                  let record = FileSearchResultMapper.record(attributes: attributes),
                  seenPaths.insert(record.result.id).inserted
            else {
                continue
            }
            results.append(record)
        }
        return results
    }
}

private final class FileQueryNotificationTarget: NSObject {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    @objc func queryDidFinish(_: Notification) {
        onFinish()
    }
}
