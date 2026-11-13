// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum WindowRuleLayoutAction: String, Codable, CaseIterable, Identifiable {
    case auto
    case tile
    case float

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .tile: "Tile"
        case .float: "Float"
        }
    }
}

enum AppRuleScratchpadConflict: Equatable, Sendable {
    case assignToWorkspace
    case tileLayout
}

struct AppRule: Codable, Identifiable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case bundleId
        case appNameSubstring
        case titleSubstring
        case titleRegex
        case axRole
        case axSubrole
        case layout
        case assignToWorkspace
        case initialContainerPrimarySpan
        case minWidth
        case minHeight
        case scratchpad
    }

    let id: UUID
    var bundleId: String
    var appNameSubstring: String?
    var titleSubstring: String?
    var titleRegex: String?
    var axRole: String?
    var axSubrole: String?
    var layout: WindowRuleLayoutAction?
    var assignToWorkspace: String?
    var initialContainerPrimarySpan: Double?
    var minWidth: Double?
    var minHeight: Double?
    var scratchpad: Int?

    init(
        id: UUID = UUID(),
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil,
        layout: WindowRuleLayoutAction? = nil,
        assignToWorkspace: String? = nil,
        initialContainerPrimarySpan: Double? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil,
        scratchpad: Int? = nil
    ) {
        self.id = id
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.layout = layout
        self.assignToWorkspace = assignToWorkspace
        self.initialContainerPrimarySpan = initialContainerPrimarySpan
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.scratchpad = scratchpad
        normalizeSingleTitle()
    }

    var effectiveLayoutAction: WindowRuleLayoutAction {
        layout ?? .auto
    }

    var validInitialContainerPrimarySpan: Double? {
        guard let initialContainerPrimarySpan,
              initialContainerPrimarySpan.isFinite,
              (0.05 ... 1.0).contains(initialContainerPrimarySpan)
        else {
            return nil
        }
        return initialContainerPrimarySpan
    }

    var assignedWorkspaceName: String? {
        guard let trimmed = assignToWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    var scratchpadConflict: AppRuleScratchpadConflict? {
        guard scratchpad != nil else { return nil }
        if assignedWorkspaceName != nil { return .assignToWorkspace }
        if effectiveLayoutAction == .tile { return .tileLayout }
        return nil
    }

    var validScratchpad: ScratchpadIndex? {
        guard let scratchpad, scratchpadConflict == nil else { return nil }
        return ScratchpadIndex(scratchpad)
    }

    var hasEffect: Bool {
        effectiveLayoutAction != .auto ||
            assignedWorkspaceName != nil ||
            validInitialContainerPrimarySpan != nil ||
            validScratchpad != nil ||
            minWidth != nil || minHeight != nil
    }

    var hasAdvancedMatchers: Bool {
        appNameSubstring?.isEmpty == false ||
            titleSubstring?.isEmpty == false ||
            titleRegex?.isEmpty == false ||
            axRole?.isEmpty == false ||
            axSubrole?.isEmpty == false
    }

    var hasBundleId: Bool {
        !bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasIdentifyingMatcher: Bool {
        hasBundleId ||
            appNameSubstring?.isEmpty == false ||
            titleSubstring?.isEmpty == false ||
            titleRegex?.isEmpty == false
    }

    var displayLabel: String {
        if hasBundleId { return bundleId }
        for candidate in [appNameSubstring, titleSubstring, titleRegex, axRole, axSubrole] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "Any window"
    }

    var specificity: Int {
        var score = 0
        if hasBundleId { score += 2 }
        if appNameSubstring?.isEmpty == false { score += 1 }
        if titleSubstring?.isEmpty == false { score += 1 }
        if titleRegex?.isEmpty == false { score += 1 }
        if axRole?.isEmpty == false { score += 1 }
        if axSubrole?.isEmpty == false { score += 1 }
        return score
    }

    var hasAnyRule: Bool {
        effectiveLayoutAction != .auto ||
            assignToWorkspace != nil ||
            initialContainerPrimarySpan != nil ||
            minWidth != nil || minHeight != nil ||
            scratchpad != nil ||
            hasAdvancedMatchers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleId = try container.decode(String.self, forKey: .bundleId)
        appNameSubstring = try container.decodeIfPresent(String.self, forKey: .appNameSubstring)
        titleSubstring = try container.decodeIfPresent(String.self, forKey: .titleSubstring)
        titleRegex = try container.decodeIfPresent(String.self, forKey: .titleRegex)
        axRole = try container.decodeIfPresent(String.self, forKey: .axRole)
        axSubrole = try container.decodeIfPresent(String.self, forKey: .axSubrole)
        layout = try container.decodeIfPresent(WindowRuleLayoutAction.self, forKey: .layout)
        assignToWorkspace = try container.decodeIfPresent(String.self, forKey: .assignToWorkspace)
        initialContainerPrimarySpan = try container.decodeIfPresent(Double.self, forKey: .initialContainerPrimarySpan)
        minWidth = try container.decodeIfPresent(Double.self, forKey: .minWidth)
        minHeight = try container.decodeIfPresent(Double.self, forKey: .minHeight)
        scratchpad = try container.decodeIfPresent(Int.self, forKey: .scratchpad)
        normalizeSingleTitle()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encodeIfPresent(appNameSubstring, forKey: .appNameSubstring)
        try container.encodeIfPresent(titleSubstring, forKey: .titleSubstring)
        try container.encodeIfPresent(titleRegex, forKey: .titleRegex)
        try container.encodeIfPresent(axRole, forKey: .axRole)
        try container.encodeIfPresent(axSubrole, forKey: .axSubrole)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(assignToWorkspace, forKey: .assignToWorkspace)
        try container.encodeIfPresent(initialContainerPrimarySpan, forKey: .initialContainerPrimarySpan)
        try container.encodeIfPresent(minWidth, forKey: .minWidth)
        try container.encodeIfPresent(minHeight, forKey: .minHeight)
        try container.encodeIfPresent(scratchpad, forKey: .scratchpad)
    }

    private mutating func normalizeSingleTitle() {
        if titleRegex?.isEmpty == false, titleSubstring?.isEmpty == false {
            titleSubstring = nil
        }
    }
}
