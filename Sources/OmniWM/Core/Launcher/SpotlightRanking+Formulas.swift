// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMLauncherSPI

extension SpotlightRanking {
    static func lengthPenalty(field: Field, length: Int) -> Float {
        guard Float(length) > field.referenceLength else { return 1 }
        let ratio = Float(length) / field.referenceLength
        return 1 / (1 + field.penaltyStrength * logf(ratio))
    }

    static func availability(present: Float) -> Float {
        0.3 * powf(present / 61.5, 0.8) + 0.7
    }

    static func launchStringScore(
        _ launchString: String,
        query: String,
        termCount: Int,
        match: TokenMatch?
    ) -> Float {
        if launchString == query { return 1 }
        guard let match,
              match.matchedTermCount >= termCount,
              match.firstTokenMatched,
              termCount == 1 || match.adjacentInOrder
        else {
            return 0
        }
        if termCount == match.textTokenCount, match.fraction >= Float(termCount) {
            return 1
        }
        if termCount == 1, match.textTokenCount == 1 {
            if match.fraction >= 0.4 { return 0.98 }
            return query.utf16.count >= 3 ? (match.fraction + 1) / 2 : match.fraction
        }
        let divisor = max(termCount, match.textTokenCount)
        guard divisor > 0 else { return 0 }
        let base = match.fraction / Float(divisor)
        return min(base * (match.adjacentInOrder ? 2 : 1), 0.99)
    }

    static func timeDecayedEngagement(dates: [Date], now: Date) -> Float {
        guard !dates.isEmpty else { return 0 }
        let confidence = Float(dates.count) / Float(dates.count + 5)
        var totalDecay = 0.0
        for date in dates {
            let exponent = date.timeIntervalSince(now) * -4.407987e-08
            totalDecay += min(1, max(0, exp(exponent)))
        }
        let meanDecay = Float(totalDecay / Double(dates.count))
        return confidence * meanDecay + (1 - confidence) * 0.709805
    }

    static func freshnessScore(date: Date?, now: Date) -> Double {
        guard let date else { return 0.5 }
        let days = floor(min(1825, max(0, now.timeIntervalSince(date) / 86400)))
        let ratio = Float(days) / 120
        let score = 0.3 * (1 / (1 + powf(ratio, 1.5)) - 0.5) + 0.5
        return Double(clamp(score, minimum: 0, maximum: 1))
    }

    static func composite(
        text: Float,
        engagement: Float,
        freshness: Double,
        context: Float,
        resultType: Float
    ) -> Float {
        let textAndEngagement = text + engagement
        let sum = Double(textAndEngagement) + freshness + Double(context) + Double(resultType)
        return clamp(Float(sum) / 5, minimum: -1, maximum: 1)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func clamp<T: Comparable>(_ value: T, minimum: T, maximum: T) -> T {
        min(maximum, max(minimum, value))
    }

    static func shimMatcher(_ evaluator: UnsafeMutableRawPointer) -> Matcher {
        { text in
            var raw = OmniWMTokenMatch()
            guard omniwm_spotlight_match(evaluator, text, &raw) else { return nil }
            return TokenMatch(
                textTokenCount: Int(raw.tokenCount),
                matchedTermCount: Int(raw.matchedTermCount),
                distinctMatchedTokenCount: Int(raw.distinctMatchedTokenCount),
                fraction: raw.matchFraction,
                firstTokenMatched: raw.firstTokenMatched.boolValue,
                lastTokenMatched: raw.lastTokenMatched.boolValue,
                adjacentInOrder: raw.adjacentInOrder.boolValue,
                matchedTermMask: raw.matchedTermMask
            )
        }
    }
}
