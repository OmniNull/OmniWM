// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum NiriContainerPrimarySpanOverride: Codable, Equatable {
    case auto
    case custom(Double)

    var customSpan: Double? {
        if case let .custom(span) = self { return span }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let span = try? container.decode(Double.self) {
            guard span.isFinite, (0.05 ... 1.0).contains(span) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a primary span between 0.05 and 1.0."
                )
            }
            self = .custom(span)
        } else {
            guard try container.decode(String.self) == "auto" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected auto or a primary span between 0.05 and 1.0."
                )
            }
            self = .auto
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case let .custom(span): try container.encode(span)
        }
    }
}

struct MonitorNiriSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var visibleContainerCount: Int?
    var defaultContainerPrimarySpan: NiriContainerPrimarySpanOverride?
    var centerFocusedColumn: CenterFocusedColumn?
    var alwaysCenterSingleColumn: Bool?
    var singleWindowFit: SingleWindowFit?
    var infiniteLoop: Bool?
    var allowOverscroll: Bool?
    var overscrollVisibleStripPercent: Int?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        visibleContainerCount: Int? = nil,
        defaultContainerPrimarySpan: NiriContainerPrimarySpanOverride? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        infiniteLoop: Bool? = nil,
        allowOverscroll: Bool? = nil,
        overscrollVisibleStripPercent: Int? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.visibleContainerCount = visibleContainerCount
        self.defaultContainerPrimarySpan = defaultContainerPrimarySpan
        self.centerFocusedColumn = centerFocusedColumn
        self.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        self.singleWindowFit = singleWindowFit
        self.infiniteLoop = infiniteLoop
        self.allowOverscroll = allowOverscroll
        self.overscrollVisibleStripPercent = overscrollVisibleStripPercent
            .map(NiriSettings.validatedOverscrollVisibleStripPercent)
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId, visibleContainerCount
        case defaultContainerPrimarySpan
        case centerFocusedColumn, alwaysCenterSingleColumn
        case singleWindowFit
        case infiniteLoop, allowOverscroll, overscrollVisibleStripPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        visibleContainerCount = try container.decodeIfPresent(Int.self, forKey: .visibleContainerCount)
        defaultContainerPrimarySpan = try container.decodeIfPresent(
            NiriContainerPrimarySpanOverride.self,
            forKey: .defaultContainerPrimarySpan
        )
        centerFocusedColumn = try container.decodeIfPresent(CenterFocusedColumn.self, forKey: .centerFocusedColumn)
        alwaysCenterSingleColumn = try container.decodeIfPresent(Bool.self, forKey: .alwaysCenterSingleColumn)
        singleWindowFit = try container.decodeIfPresent(SingleWindowFit.self, forKey: .singleWindowFit)
        infiniteLoop = try container.decodeIfPresent(Bool.self, forKey: .infiniteLoop)
        allowOverscroll = try container.decodeIfPresent(Bool.self, forKey: .allowOverscroll)
        overscrollVisibleStripPercent = try container.decodeIfPresent(Int.self, forKey: .overscrollVisibleStripPercent)
            .map(NiriSettings.validatedOverscrollVisibleStripPercent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try DisplayUUID.encode(
            monitorDisplayUUID,
            displayId: monitorDisplayId,
            to: &container,
            uuidKey: .monitorDisplayUUID,
            displayIdKey: .monitorDisplayId
        )
        try container.encodeIfPresent(visibleContainerCount, forKey: .visibleContainerCount)
        try container.encodeIfPresent(defaultContainerPrimarySpan, forKey: .defaultContainerPrimarySpan)
        try container.encodeIfPresent(centerFocusedColumn, forKey: .centerFocusedColumn)
        try container.encodeIfPresent(alwaysCenterSingleColumn, forKey: .alwaysCenterSingleColumn)
        try container.encodeIfPresent(singleWindowFit, forKey: .singleWindowFit)
        try container.encodeIfPresent(infiniteLoop, forKey: .infiniteLoop)
        try container.encodeIfPresent(allowOverscroll, forKey: .allowOverscroll)
        try container.encodeIfPresent(overscrollVisibleStripPercent, forKey: .overscrollVisibleStripPercent)
    }
}

struct ResolvedNiriSettings: Equatable {
    let visibleContainerCount: Int
    let defaultContainerPrimarySpan: Double?
    let centerFocusedColumn: CenterFocusedColumn
    let alwaysCenterSingleColumn: Bool
    let singleWindowFit: SingleWindowFit
    let infiniteLoop: Bool
    var edgeOverscroll: NiriEdgeOverscroll = .disabled
}
