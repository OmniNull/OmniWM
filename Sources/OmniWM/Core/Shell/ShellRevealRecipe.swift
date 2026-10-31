// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct ShellRevealRecipe: Equatable, Sendable {
    let response: Double
    let bounce: Double
    let delay: Double
    let hold: Double
    let exits: Bool

    init?(_ source: String) {
        guard let record = ShellRecipeFields(source, prefix: "reveal", count: 3, limit: 256, allowed: ["shape"]) else {
            return nil
        }
        let fields = record.base
        guard
            let response = Double(fields[1]), response.isFinite, (0.05 ... 2.5).contains(response),
            let bounce = Double(fields[2]), bounce.isFinite, (0 ... 0.95).contains(bounce)
        else { return nil }
        if let shape = record.sections["shape"] {
            guard shape.count == 3, let delay = ShellRecipeFields.number(shape[0], in: 0 ... 2),
                  let hold = ShellRecipeFields.number(shape[1], in: 0 ... 2),
                  let exits = ShellRecipeFields.flag(shape[2])
            else { return nil }
            self.delay = delay
            self.hold = hold
            self.exits = exits
        } else {
            delay = 0
            hold = 0
            exits = true
        }
        self.response = response
        self.bounce = bounce
    }
}

struct ShellMorphRecipe: Equatable, Sendable {
    struct Stretch: Equatable, Sendable {
        let gain: Double
        let max: Double
        let width: Double
        let height: Double
    }

    struct Stop: Equatable, Sendable {
        let at: Double
        let scale: Double
        let opacity: Double
        let width: Double
        let height: Double
        let round: Double
        var dx: Double = 0
        var dy: Double = 0
        var thickness: Double = 1
    }

    struct Spring: Equatable, Sendable {
        let response: Double
        let bounce: Double
    }

    enum ImpulseKind: Int, Sendable {
        case at
        case after
    }

    enum ImpulsePivot: Int, Sendable {
        case anchor
        case centre
    }

    enum ImpulsePhase: Int, Sendable {
        case both
        case open
        case close
    }

    struct Impulse: Equatable, Sendable {
        let kind: ImpulseKind
        let time: Double
        let rising: Bool
        let spring: Spring
        let velocity: Double
        let width: Double
        let height: Double
        let pivot: ImpulsePivot
        var phase: ImpulsePhase = .both
    }

    struct Edges: Equatable, Sendable {
        let lead: Spring
        let trail: Spring
        let thin: Double
        let unit: Double
    }

    enum SourceEdge: Int, Sendable {
        case top
        case left
        case right
        case bottom
    }

    struct Pads: Equatable, Sendable {
        let left: Double
        let right: Double
        let top: Double
        let bottom: Double
    }

    struct Adhesion: Equatable, Sendable {
        var top: Double?
        var left: Double?
        var right: Double?
        var bottom: Double?

        func from(_ edge: SourceEdge) -> Double? {
            switch edge {
            case .top: top
            case .left: left
            case .right: right
            case .bottom: bottom
            }
        }
    }

    struct Source: Equatable, Sendable {
        let target: UInt64
        let edge: SourceEdge
        let from: Double
        let span: Double
        let pads: Pads?
        var adhere = Adhesion()
        var contact = false
    }

    struct Trigger: Equatable, Sendable {
        let shape: UInt64
        let at: Double
        let rising: Bool
        var contact = false
    }

    let anchor: CGPoint
    let stretch: Stretch
    let stops: [Stop]
    let impulses: [Impulse]
    let edges: Edges?
    let source: Source?
    let trigger: Trigger?
    let beat: Bool
    let track: UInt64?

    var waits: Bool {
        trigger != nil || beat
    }

    init?(_ source: String) {
        guard let recipe = ShellRecipeFields(
            source, prefix: "morph", count: 8, limit: 1536,
            allowed: [
                "offsets",
                "impulses",
                "impulsePhases",
                "edges",
                "source",
                "adhere",
                "trigger",
                "beat",
                "track",
                "sourceContact",
                "triggerContact"
            ]
        ) else { return nil }
        let fields = recipe.base
        guard
            let ax = Self.number(fields[1], in: 0 ... 1), let ay = Self.number(fields[2], in: 0 ... 1),
            let gain = Self.number(fields[3], in: 0 ... 1_000_000),
            let max = Self.number(fields[4], in: 0 ... 1_000_000),
            let width = Self.number(fields[5], in: -1_000_000 ... 1_000_000),
            let height = Self.number(fields[6], in: -1_000_000 ... 1_000_000)
        else { return nil }
        guard let stops = Self.stops(fields[7], sections: recipe.sections) else { return nil }
        guard let impulses = Self.impulses(recipe.sections["impulses"], phases: recipe.sections["impulsePhases"])
        else { return nil }
        if let values = recipe.sections["edges"] {
            guard let edges = Self.edges(values) else { return nil }
            self.edges = edges
        } else { edges = nil }
        guard let bindings = Self.bindings(recipe) else { return nil }
        self.source = bindings.source
        trigger = bindings.trigger
        beat = bindings.beat
        track = bindings.track
        anchor = CGPoint(x: ax, y: ay)
        stretch = Stretch(gain: gain, max: max, width: width, height: height)
        self.stops = stops
        self.impulses = impulses
    }
}

extension ShellMorphRecipe {
    private struct Bindings {
        let source: Source?
        let trigger: Trigger?
        let beat: Bool
        let track: UInt64?
    }

    private static func bindings(_ recipe: ShellRecipeFields) -> Bindings? {
        var source: Source?
        var trigger: Trigger?
        var track: UInt64?
        if let values = recipe.sections["source"] {
            guard let parsed = Self.source(
                values,
                adhere: recipe.sections["adhere"],
                contact: recipe.sections["sourceContact"]
            ) else { return nil }
            source = parsed
        }
        if let values = recipe.sections["trigger"] {
            guard let parsed = Self.trigger(values, contact: recipe.sections["triggerContact"]) else { return nil }
            trigger = parsed
        }
        if let values = recipe.sections["track"] {
            let fields = recipe.base
            guard values.count == 1, let key = UInt64(values[0]), key != 0,
                  recipe.sections.count == 1,
                  fields[1] == "0.5", fields[2] == "0.5", fields[3] == "0", fields[4] == "0",
                  fields[5] == "0", fields[6] == "0",
                  fields[7] == "0,1,1,1,1,1;1,1,1,1,1,1" else { return nil }
            track = key
        }
        let beat = recipe.sections["beat"] != nil
        guard recipe.sections["adhere"] == nil || source != nil,
              recipe.sections["sourceContact"] == nil || source != nil,
              recipe.sections["triggerContact"] == nil || trigger != nil, source == nil || trigger == nil,
              recipe.sections["beat"].map({ $0 == ["1"] }) ?? true, !beat || (source == nil && trigger == nil)
        else { return nil }
        return Bindings(source: source, trigger: trigger, beat: beat, track: track)
    }

    private static func number(_ field: Substring, in range: ClosedRange<Double>) -> Double? {
        ShellRecipeFields.number(field, in: range)
    }

    private static func stops(_ record: Substring, sections: [Substring: [Substring]]) -> [Stop]? {
        if sections["edges"] != nil, record != "0,1,1,1,1,1;1,1,1,1,1,1" { return nil }
        let records = record.split(separator: ";", omittingEmptySubsequences: false)
        guard (2 ... 16).contains(records.count) else { return nil }
        var stops: [Stop] = []
        stops.reserveCapacity(records.count)
        for record in records {
            guard let stop = stop(record), stops.last.map({ $0.at < stop.at }) ?? true else { return nil }
            stops.append(stop)
        }
        if let offsets = sections["offsets"], !Self.offsets(offsets, into: &stops) { return nil }
        return stops
    }

    private static func stop(_ record: Substring) -> Stop? {
        let fields = record.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 6,
              let at = number(fields[0], in: -0.5 ... 1.5),
              let scale = number(fields[1], in: 0 ... 1_000_000),
              let opacity = number(fields[2], in: 0 ... 1),
              let width = number(fields[3], in: 0 ... 1_000_000),
              let height = number(fields[4], in: 0 ... 1_000_000),
              let round = number(fields[5], in: 0 ... 1)
        else { return nil }
        return Stop(at: at, scale: scale, opacity: opacity, width: width, height: height, round: round)
    }

    private static func offsets(_ fields: [Substring], into stops: inout [Stop]) -> Bool {
        guard fields.count == 1 else { return false }
        let records = fields[0].split(separator: ";", omittingEmptySubsequences: false)
        guard records.count == stops.count else { return false }
        for (index, record) in records.enumerated() {
            let values = record.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 3,
                  let dx = number(values[0], in: -1_000_000 ... 1_000_000),
                  let dy = number(values[1], in: -1_000_000 ... 1_000_000),
                  let thickness = number(values[2], in: 0 ... 1_000_000)
            else { return false }
            stops[index].dx = dx
            stops[index].dy = dy
            stops[index].thickness = thickness
        }
        return true
    }

    private static func spring(_ response: Substring, _ bounce: Substring) -> Spring? {
        guard let response = number(response, in: 0.05 ... 2.5), let bounce = number(bounce, in: 0 ... 0.95) else {
            return nil
        }
        return Spring(response: response, bounce: bounce)
    }

    private static func impulses(_ fields: [Substring]?, phases: [Substring]?) -> [Impulse]? {
        guard let fields else { return phases == nil ? [] : nil }
        guard fields.count == 1 else { return nil }
        let records = fields[0].split(separator: ";", omittingEmptySubsequences: false)
        guard (1 ... 8).contains(records.count) else { return nil }
        var impulses: [Impulse] = []
        for record in records {
            let values = record.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 9, let rawKind = Int(values[0]), let kind = ImpulseKind(rawValue: rawKind),
                  let time = number(values[1], in: kind == .at ? -0.5 ... 1.5 : 0 ... 30),
                  let rising = ShellRecipeFields.flag(values[2]), let spring = spring(values[3], values[4]),
                  let velocity = number(values[5], in: -1_000_000 ... 1_000_000),
                  let width = number(values[6], in: -1_000_000 ... 1_000_000),
                  let height = number(values[7], in: -1_000_000 ... 1_000_000),
                  let rawPivot = Int(values[8]), let pivot = ImpulsePivot(rawValue: rawPivot)
            else { return nil }
            impulses.append(Impulse(
                kind: kind, time: time, rising: rising, spring: spring, velocity: velocity,
                width: width, height: height, pivot: pivot
            ))
        }
        return Self.phased(impulses, phases)
    }

    private static func phased(_ values: [Impulse], _ fields: [Substring]?) -> [Impulse]? {
        guard let fields else { return values }
        guard fields.count == values.count else { return nil }
        var impulses = values
        for index in impulses.indices {
            guard let raw = Int(fields[index]), let phase = ImpulsePhase(rawValue: raw) else { return nil }
            impulses[index].phase = phase
        }
        return impulses
    }

    private static func edges(_ values: [Substring]) -> Edges? {
        guard values.count == 6, let lead = spring(values[0], values[1]), let trail = spring(values[2], values[3]),
              let thin = number(values[4], in: 0 ... 1),
              let unit = number(values[5], in: 0 ... 1_000_000), unit > 0
        else { return nil }
        return Edges(lead: lead, trail: trail, thin: thin, unit: unit)
    }

    private static func source(
        _ values: [Substring], adhere: [Substring]?, contact: [Substring]?
    ) -> Source? {
        guard values.count == 9, let target = UInt64(values[0]), target != 0,
              let rawEdge = Int(values[1]), let edge = SourceEdge(rawValue: rawEdge),
              let from = number(values[2], in: -1_000_000 ... 1_000_000),
              let span = number(values[3], in: 0 ... 1_000_000), span > 0,
              let hasPads = ShellRecipeFields.flag(values[4]),
              let left = number(values[5], in: -1_000_000 ... 1_000_000),
              let right = number(values[6], in: -1_000_000 ... 1_000_000),
              let top = number(values[7], in: -1_000_000 ... 1_000_000),
              let bottom = number(values[8], in: -1_000_000 ... 1_000_000)
        else { return nil }
        guard let adherence = adhesion(adhere), adherence.from(edge) == nil,
              let contact = contactFlag(contact), !contact || !hasPads else { return nil }
        return Source(
            target: target, edge: edge, from: from, span: span,
            pads: hasPads ? Pads(left: left, right: right, top: top, bottom: bottom) : nil,
            adhere: adherence, contact: contact
        )
    }

    private static func adhesion(_ values: [Substring]?) -> Adhesion? {
        guard let values else { return Adhesion() }
        guard values.count == 8 else { return nil }
        var result: [Double?] = []
        for index in stride(from: 0, to: values.count, by: 2) {
            guard let present = ShellRecipeFields.flag(values[index]),
                  let from = number(values[index + 1], in: -1_000_000 ... 1_000_000) else { return nil }
            result.append(present ? from : nil)
        }
        return Adhesion(top: result[0], left: result[1], right: result[2], bottom: result[3])
    }

    private static func contactFlag(_ values: [Substring]?) -> Bool? {
        guard let values else { return false }
        guard values.count == 1 else { return nil }
        return ShellRecipeFields.flag(values[0])
    }

    private static func trigger(_ values: [Substring], contact: [Substring]?) -> Trigger? {
        guard values.count == 3, let shape = UInt64(values[0]), shape != 0,
              let at = number(values[1], in: -0.5 ... 1.5), let rising = ShellRecipeFields.flag(values[2])
        else { return nil }
        guard let contact = contactFlag(contact) else { return nil }
        return Trigger(shape: shape, at: at, rising: rising, contact: contact)
    }
}
