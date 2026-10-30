// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ShellPulseRecipe: Equatable, Sendable {
    let key: UInt64
    let duration: Double
    let rotate: [Double]
    let scale: [Double]
    let dx: [Double]
    let dy: [Double]

    init?(_ source: String) {
        guard let fields = ShellRecipeFields(source, prefix: "pulse", count: 7, limit: 16_384)?.base,
              let key = UInt64(fields[1]), key != 0,
              let duration = ShellRecipeFields.number(fields[2], in: 0 ... 30), duration > 0,
              let rotate = Self.channel(fields[3]), zip(rotate, rotate.dropFirst()).allSatisfy({ abs($0 - $1) < 180 }),
              let scale = Self.channel(fields[4]),
              let dx = Self.channel(fields[5]), let dy = Self.channel(fields[6]),
              !rotate.isEmpty || !scale.isEmpty || !dx.isEmpty || !dy.isEmpty
        else { return nil }
        self.key = key
        self.duration = duration
        self.rotate = rotate
        self.scale = scale
        self.dx = dx
        self.dy = dy
    }

    private static func channel(_ record: Substring) -> [Double]? {
        if record.isEmpty { return [] }
        let fields = record.split(separator: ",", omittingEmptySubsequences: false)
        guard (2 ... 256).contains(fields.count), fields.last.flatMap(Double.init) == 0 else { return nil }
        let values = fields.compactMap { ShellRecipeFields.number($0, in: -1_000_000 ... 1_000_000) }
        return values.count == fields.count ? values : nil
    }
}

struct ShellRecipeFields {
    let base: [Substring]
    let sections: [Substring: [Substring]]

    init?(_ source: String, prefix: Substring, count: Int, limit: Int, allowed: Set<Substring> = []) {
        guard source.utf8.count <= limit else { return nil }
        let records = source.split(separator: "|", omittingEmptySubsequences: false)
        guard let first = records.first else { return nil }
        let base = first.split(separator: ":", omittingEmptySubsequences: false)
        guard base.count == count, base[0] == prefix else { return nil }
        var sections: [Substring: [Substring]] = [:]
        for record in records.dropFirst() {
            let fields = record.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count > 1, let key = fields.first, allowed.contains(key),
                  sections[key] == nil else { return nil }
            sections[key] = Array(fields.dropFirst())
        }
        self.base = base
        self.sections = sections
    }

    static func number(_ field: Substring, in range: ClosedRange<Double>) -> Double? {
        guard let value = Double(field), value.isFinite, range.contains(value) else { return nil }
        return value
    }

    static func flag(_ field: Substring) -> Bool? {
        switch field {
        case "0": false
        case "1": true
        default: nil
        }
    }
}
