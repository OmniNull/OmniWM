// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum SpotlightRanking {
    struct Field: Sendable, Equatable {
        static let nameFlag: UInt8 = 1
        static let normalizedFlag: UInt8 = 2
        static let exactFlag: UInt8 = 4
        static let coverageFlag: UInt8 = 8

        let weight: Float
        let referenceLength: Float
        let penaltyStrength: Float
        private let flags: UInt8

        private init(_ weight: Float, _ referenceLength: Float, _ penaltyStrength: Float = 0.2, _ flags: UInt8 = 0) {
            self.weight = weight
            self.referenceLength = referenceLength
            self.penaltyStrength = penaltyStrength
            self.flags = flags
        }

        static let displayName = Self(9, 16, 0.2, nameFlag | normalizedFlag | exactFlag | coverageFlag)
        static let alternateName = Self(9, 16, 0.2, nameFlag | normalizedFlag | coverageFlag)
        static let identifier = Self(7, 16, 0.2, nameFlag | normalizedFlag | exactFlag | coverageFlag)
        static let path = Self(7, 8, 0.2, nameFlag | normalizedFlag)
        static let initials = Self(6, 5, 0.2, nameFlag)
        static let authors = Self(6, 20)
        static let title = Self(5.5, 30, 0.2, normalizedFlag)
        static let description = Self(4, 20, 0.35)
        static let fileSystemName = Self(2, 100, 0.4, nameFlag | normalizedFlag)
        static let kind = Self(2, 20)
        static let contentURL = Self(2, 80, 0.8)
        static let snippet = Self(2, 80, 0.8)

        func contains(_ flag: UInt8) -> Bool {
            flags & flag != 0
        }
    }

    struct TokenMatch: Sendable {
        var textTokenCount: Int
        var matchedTermCount: Int
        var distinctMatchedTokenCount: Int
        var fraction: Float
        var firstTokenMatched, lastTokenMatched, adjacentInOrder: Bool
        var matchedTermMask: UInt64 = 0
    }

    struct Fields: Sendable {
        var displayName: String
        var alternateNames: [String] = []
        var foldedAlternateNames: [String] = []
        var identifier, path, initials, authors, title, description: String?
        var fileSystemName, kind, contentURL, snippet: String?
    }

    enum ResultType: Sendable {
        case application
        case folder
        case developer
        case other
        case typedFile

        var score: Float {
            switch self {
            case .application: 0.25
            case .folder,
                 .typedFile: 0
            case .developer: -0.4
            case .other: -0.2
            }
        }
    }

    struct Engagement: Sendable {
        var inSpotlightDates: [Date] = []
        var inSpotlightQueries: [String] = []
        var outOfSpotlightDates: [Date] = []
        var useCount = 0
    }

    struct Candidate: Sendable {
        var id: String
        var fields: Fields
        var resultType: ResultType
        var engagement = Engagement()
        var lastUsedDate, modifiedDate, createdDate: Date?
    }

    struct Score: Sendable {
        var text, engagement: Float
        var freshness: Double
        var resultType, composite: Float
    }

    struct RankedCandidate: Sendable {
        var id: String
        var displayName: String
        var score: Score
        var freshnessDate: Date?
    }

    typealias Matcher = (String) -> TokenMatch?
}

extension SpotlightRanking {
    static func score(
        query: String,
        termCount: Int,
        candidate: Candidate,
        match: @escaping Matcher
    ) -> RankedCandidate? {
        guard termCount > 0, !query.isEmpty else { return nil }
        return score(candidate, context: QueryContext(query: query, termCount: termCount, match: match), admit: true)
    }

    static func rank(
        query: String,
        termCount: Int,
        candidates: [Candidate],
        shortcuts: [String: String] = [:],
        admitUnmatched: Bool = false,
        shouldCancel: () -> Bool = { false },
        match: @escaping Matcher
    ) -> [RankedCandidate] {
        guard termCount > 0, !query.isEmpty else { return [] }
        let context = QueryContext(query: query, termCount: termCount, match: match)
        let shortcutID = shortcuts[query.localizedLowercase]
        var results: [RankedCandidate] = []
        results.reserveCapacity(candidates.count)
        for candidate in candidates {
            if shouldCancel() { return [] }
            if let result = score(candidate, context: context, admit: admitUnmatched || candidate.id == shortcutID) {
                results.append(result)
            }
        }
        results.sort { left, right in
            if left.id == shortcutID { return right.id != shortcutID }
            if right.id == shortcutID { return false }
            return precedes(left, right)
        }
        return results
    }

    private static func score(
        _ candidate: Candidate,
        context: QueryContext,
        admit: Bool
    ) -> RankedCandidate? {
        var fields = FieldAccumulator()
        fields.add(.displayName, candidate.fields.displayName, context: context)
        if let alternate = firstMatchedAlternate(candidate.fields, context) {
            fields.add(.alternateName, alternate.text, context: context, existingMatch: alternate.match)
        }
        fields.add(.identifier, candidate.fields.identifier, context: context)
        fields.add(.path, candidate.fields.path, context: context)
        fields.add(.initials, candidate.fields.initials, context: context)
        fields.add(.authors, candidate.fields.authors, context: context)
        fields.add(.title, candidate.fields.title, context: context)
        fields.add(.description, candidate.fields.description, context: context)
        if context.termCount > 1 {
            fields.add(.fileSystemName, candidate.fields.fileSystemName, context: context)
            fields.add(.kind, candidate.fields.kind, context: context)
        }
        fields.add(.contentURL, candidate.fields.contentURL, context: context)
        fields.add(.snippet, candidate.fields.snippet, context: context)

        guard admit || fields.coversAllTerms(context.termCount) else { return nil }
        let text = fields.textScore(context: context)
        let now = context.now
        let engagement = engagementScore(candidate.engagement, textScore: text, context: context, now: now)
        let freshnessDate = freshnessDate(for: candidate, now: now)
        let freshness = freshnessScore(date: freshnessDate, now: now)
        let resultType = candidate.resultType.score
        let score = Score(
            text: text,
            engagement: engagement,
            freshness: freshness,
            resultType: resultType,
            composite: composite(
                text: text,
                engagement: engagement,
                freshness: freshness,
                context: 0,
                resultType: resultType
            )
        )
        return RankedCandidate(
            id: candidate.id,
            displayName: candidate.fields.displayName,
            score: score,
            freshnessDate: freshnessDate
        )
    }

    private static func firstMatchedAlternate(
        _ fields: Fields,
        _ context: QueryContext
    ) -> (text: String, match: TokenMatch)? {
        for (index, name) in fields.alternateNames.enumerated() {
            if fields.foldedAlternateNames.indices.contains(index),
               !context.foldedTerms.allSatisfy(fields.foldedAlternateNames[index].contains)
            {
                continue
            }
            if let match = context.match(name), match.matchedTermCount == context.termCount {
                return (name, match)
            }
        }
        return nil
    }

    private static func precedes(_ left: RankedCandidate, _ right: RankedCandidate) -> Bool {
        if left.score.composite != right.score.composite { return left.score.composite > right.score.composite }
        if left.score.text != right.score.text { return left.score.text > right.score.text }
        if left.score.engagement != right.score.engagement { return left.score.engagement > right.score.engagement }
        if let leftDate = left.freshnessDate, let rightDate = right.freshnessDate {
            let leftSecond = floor(leftDate.timeIntervalSince1970)
            let rightSecond = floor(rightDate.timeIntervalSince1970)
            if leftSecond != rightSecond { return leftSecond > rightSecond }
        } else if left.score.freshness != right.score.freshness {
            return left.score.freshness > right.score.freshness
        }
        let leftName = left.displayName.lowercased()
        let rightName = right.displayName.lowercased()
        if leftName.utf16.count != rightName.utf16.count { return leftName.utf16.count < rightName.utf16.count }
        return leftName.compare(rightName) == .orderedAscending
    }

    private struct QueryContext {
        var query: String
        var lowercasedQuery: String
        var foldedTerms: [String]
        var termCount: Int
        var queryLength: Int
        var match: Matcher
        var now: Date

        init(query: String, termCount: Int, match: @escaping Matcher) {
            self.query = query
            self.lowercasedQuery = query.lowercased()
            self.foldedTerms = query.split(whereSeparator: \.isWhitespace).map { SpotlightRanking.fold(String($0)) }
            self.termCount = termCount
            self.queryLength = query.utf16.count
            self.match = match
            self.now = Date()
        }
    }

    private struct FieldAccumulator {
        var nonNameWeight: Float = 0
        var nonNameWeightedScore: Float = 0
        var nameWeight: Float = 0
        var nameScore: Float = 0
        var containingWeight: Float = 0
        var prefixWeight: Float = 0
        var nonInitialPrefixWeight: Float = 0
        var exactWeight: Float = 0
        var coverage: Float = 0
        var matchCount = 0
        var highestMatchCount = 0
        var matchedFields = 0
        var matchedTermMask: UInt64 = 0
        var hasCompleteFieldMatch = false

        mutating func add(
            _ field: Field,
            _ text: String?,
            context: QueryContext,
            existingMatch: TokenMatch? = nil
        ) {
            guard let text, !text.isEmpty else { return }
            let selected = SpotlightRanking.selectedMatch(field, text, context, existingMatch)
            let effectiveText = selected.text
            let tokenMatch = selected.match
            let weight = field.weight
            let penalty = SpotlightRanking.fieldPenalty(field, effectiveText, tokenMatch, context.termCount)
            if field.contains(Field.nameFlag) {
                nameWeight = max(nameWeight, weight)
                nameScore = max(nameScore, penalty)
            } else {
                nonNameWeight += weight
                nonNameWeightedScore += weight * penalty
            }
            addBonuses(field, text: effectiveText, match: tokenMatch, context: context)
        }

        func textScore(context: QueryContext) -> Float {
            let present = nonNameWeight + nameWeight
            guard present > 0 else { return 0 }
            let base = (nonNameWeightedScore + nameWeight * nameScore) / present
            let phrase = containingWeight > 0
                ? containingWeight * (prefixWeight >= containingWeight ? 0.18 : 0.12) / 9
                : 0
            let exact = 0.3 * exactWeight / 9
            let concentration = concentrationBonus(termCount: context.termCount)
            let bonuses = min(phrase + exact + coverage + concentration, 0.6)
            if context.termCount > 1 {
                return SpotlightRanking.clamp(bonuses * (1 - base) + base, minimum: 0, maximum: 1)
            }

            let specificity = max(0.5, context.queryLength < 3 ? 0 : min(1, 0.25 * Float(context.queryLength - 2)))
            let availability = SpotlightRanking.availability(present: present)
            let adjustedBase = (0.5 * specificity + 0.5) * base * availability
            let prefix = availability * specificity * nonInitialPrefixWeight / 9 * 0.12
            return SpotlightRanking.clamp(
                bonuses * max(0, 1 - adjustedBase - prefix) + prefix + adjustedBase,
                minimum: 0,
                maximum: 1
            )
        }

        private mutating func addBonuses(
            _ field: Field,
            text: String,
            match: TokenMatch?,
            context: QueryContext
        ) {
            let lowercased = text.lowercased()
            let isPrefix = lowercased.hasPrefix(context.lowercasedQuery)
            if lowercased.contains(context.lowercasedQuery) { containingWeight = max(containingWeight, field.weight) }
            if isPrefix {
                prefixWeight = max(prefixWeight, field.weight)
                if field != .initials { nonInitialPrefixWeight = max(nonInitialPrefixWeight, field.weight) }
            }
            if field.contains(Field.exactFlag),
               text.compare(context.query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            {
                exactWeight = max(exactWeight, field.weight)
            }
            if field.contains(Field.coverageFlag) { addCoverage(field, text, match, context, isPrefix) }
            if let match, match.matchedTermCount > 0 {
                matchCount += match.matchedTermCount
                highestMatchCount = max(highestMatchCount, match.matchedTermCount)
                matchedFields += 1
                matchedTermMask |= match.matchedTermMask
                hasCompleteFieldMatch = hasCompleteFieldMatch || match.matchedTermCount >= context.termCount
            }
        }

        func coversAllTerms(_ termCount: Int) -> Bool {
            guard termCount > 0 else { return false }
            let allTerms: UInt64 = termCount >= 64 ? .max : (1 << UInt64(termCount)) - 1
            return hasCompleteFieldMatch || matchedTermMask & allTerms == allTerms
        }

        private mutating func addCoverage(
            _ field: Field,
            _ text: String,
            _ match: TokenMatch?,
            _ context: QueryContext,
            _ isPrefix: Bool
        ) {
            if context.termCount == 1 {
                guard context.queryLength > 1, isPrefix else { return }
                let fraction = Float(context.queryLength) / Float(text.utf16.count)
                coverage = max(coverage, 0.3 * fraction * field.weight / 9)
            } else if let match, match.textTokenCount > 0 {
                let fraction = min(1, Float(match.distinctMatchedTokenCount) / Float(match.textTokenCount))
                coverage = max(coverage, 0.3 * fraction * field.weight / 9)
            }
        }

        private func concentrationBonus(termCount: Int) -> Float {
            guard termCount >= 2, matchCount >= 2 else { return 0 }
            let concentration = Float(highestMatchCount) / Float(matchCount)
            if concentration == 1 { return 0.12 }
            if concentration >= 0.8 { return 0.06 }
            return matchedFields <= 3 ? 0.03 : 0
        }
    }

    private static let normalizedSeparators = Set("|/\\:. -()~*&_".map { $0 })

    private static func selectedMatch(
        _ field: Field,
        _ text: String,
        _ context: QueryContext,
        _ existingMatch: TokenMatch?
    ) -> (text: String, match: TokenMatch?) {
        let original = existingMatch ?? context.match(text)
        guard field.contains(Field.normalizedFlag), text.contains(where: normalizedSeparators.contains) else {
            return (text, original)
        }
        let normalized = String(text.map { normalizedSeparators.contains($0) ? " " : String($0) }.joined())
        guard normalized != text else { return (text, original) }
        let normalizedMatch = context.match(normalized)
        if (normalizedMatch?.distinctMatchedTokenCount ?? 0) > (original?.distinctMatchedTokenCount ?? 0) {
            return (normalized, normalizedMatch)
        }
        return (text, original)
    }

    private static func fieldPenalty(_ field: Field, _ text: String, _ match: TokenMatch?, _ termCount: Int) -> Float {
        guard let match, match.matchedTermCount > 0 else { return 0 }
        let coverage = Float(match.matchedTermCount) / Float(termCount)
        let firstLast = termCount >= 3
            ? 2 * (0.25 * Float(match.firstTokenMatched ? 1 : 0) + 0.25 * Float(match.lastTokenMatched ? 1 : 0))
            : 0
        let adjacent = match.adjacentInOrder ? Float(0.5) : 0
        let raw = min(1, 0.15 * adjacent + (0.2 * firstLast + coverage))
        return lengthPenalty(field: field, length: text.utf16.count) * raw
    }

    private static func engagementScore(
        _ engagement: Engagement,
        textScore: Float,
        context: QueryContext,
        now: Date
    ) -> Float {
        if !engagement.inSpotlightDates.isEmpty {
            if engagement.inSpotlightDates.count != engagement.inSpotlightQueries.count {
                return timeDecayedEngagement(dates: engagement.inSpotlightDates, now: now)
            }
            var matchingDates: [Date] = []
            matchingDates.reserveCapacity(engagement.inSpotlightDates.count)
            for (query, date) in zip(engagement.inSpotlightQueries, engagement.inSpotlightDates) {
                let tokenMatch = context.match(query)
                let score = launchStringScore(
                    query,
                    query: context.query,
                    termCount: context.termCount,
                    match: tokenMatch
                )
                if score >= 0.9 { matchingDates.append(date) }
            }
            return timeDecayedEngagement(dates: matchingDates, now: now)
        }
        guard textScore > 0 else { return 0 }
        let outOfSpotlight = timeDecayedEngagement(dates: engagement.outOfSpotlightDates, now: now)
        let useCount = max(0, engagement.useCount)
        let saturation = min(1, logf(Float(useCount + 1)) / logf(50))
        return 0.1 * max(outOfSpotlight, saturation)
    }

    private static func freshnessDate(for candidate: Candidate, now: Date) -> Date? {
        if candidate.resultType == .application { return candidate.lastUsedDate }
        switch (candidate.modifiedDate, candidate.createdDate) {
        case let (modified?, created?):
            return abs(modified.timeIntervalSince(now)) <= abs(created.timeIntervalSince(now)) ? modified : created
        case let (modified?, nil): return modified
        case let (nil, created?): return created
        case (nil, nil): return nil
        }
    }
}
