// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellGlassCapability: Sendable {
    enum EffectKey: String, Sendable {
        case color
        case offset
        case radius
        case punchout
        case keyColor
        case keyAngle
        case keyHeight
        case keySpread
        case keyAmount
        case fillColor
        case fillAngle
        case fillHeight
        case fillSpread
        case fillAmount
        case curvature
        case diffuseHeightScale
        case diffuseAmountScale
        case diffuseSpreadScale
        case colors
        case distances
    }

    enum Effect: String, CaseIterable, Sendable {
        case shadow = "CASDFShadowEffect"
        case fill = "CASDFFillEffect"
        case highlight = "CASDFKeyFillHighlightEffect"
        case band = "CASDFGradientEffect"

        var keys: [EffectKey] {
            switch self {
            case .shadow: [.color, .offset, .radius, .punchout]
            case .fill: [.color]
            case .band: [.colors, .distances]
            case .highlight:
                [
                    .keyColor,
                    .keyAngle,
                    .keyHeight,
                    .keySpread,
                    .keyAmount,
                    .fillColor,
                    .fillAngle,
                    .fillHeight,
                    .fillSpread,
                    .fillAmount,
                    .curvature,
                    .diffuseHeightScale,
                    .diffuseAmountScale,
                    .diffuseSpreadScale
                ]
            }
        }
    }

    enum BodyProperty: String, CaseIterable {
        case effect
        case smoothness
        case effectOffset
    }

    enum ElementProperty: String, CaseIterable {
        case mode
        case operation
    }

    enum BackdropProperty: String, CaseIterable {
        case windowServerAware
    }

    enum Compositing: String {
        case add = "plusL"
    }

    static let sdfClassNames = ["CASDFLayer", "CASDFElementLayer", "CAFilter"] + Effect.allCases.map(\.rawValue)
    static let classNames = ["CABackdropLayer"] + sdfClassNames

    static let shared: ShellGlassCapability = {
        let capability = ShellGlassCapability()
        if let missing = capability.missing {
            FallbackFiringRecorder.shared.note(.system, "shellGlass:\(missing)")
            Log.shell.notice("Native glass unavailable: \(missing); using plain material and tint")
        }
        return capability
    }()

    let bodyClass: CALayer.Type?
    let elementClass: CALayer.Type?
    let backdropClass: CALayer.Type?
    let backdropAware: Bool
    let missing: String?
    let flatMissing: String?
    private let effectClasses: [Effect: NSObject.Type]
    private let filterClass: NSObject.Type?

    var available: Bool {
        missing == nil
    }

    func missing(backdrop: Bool) -> String? {
        backdrop ? missing : flatMissing
    }

    func backdrop() -> CALayer {
        let layer = backdropClass?.init() ?? CALayer()
        if backdropAware { layer.setValue(true, forKey: BackdropProperty.windowServerAware.rawValue) }
        return layer
    }

    init(denying requirement: String? = nil) {
        let classes = Dictionary(uniqueKeysWithValues: Self.classNames.compactMap { name in
            (NSClassFromString(name) as? NSObject.Type).map { (name, $0) }
        })
        bodyClass = classes["CASDFLayer"] as? CALayer.Type
        elementClass = classes["CASDFElementLayer"] as? CALayer.Type
        backdropClass = classes["CABackdropLayer"] as? CALayer.Type
        filterClass = classes["CAFilter"]
        effectClasses = Dictionary(uniqueKeysWithValues: Effect.allCases.compactMap { effect in
            classes[effect.rawValue].map { (effect, $0) }
        })
        let hasSetter: (String, String) -> Bool = { name, key in
            guard let type = classes[name] else { return false }
            return requirement != "\(name).\(key)" && type
                .instancesRespond(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):"))
        }
        backdropAware = hasSetter("CABackdropLayer", BackdropProperty.windowServerAware.rawValue)
        missing = Self.firstMissing(classAvailable: { classes[$0] != nil }, setterAvailable: hasSetter)
        flatMissing = Self.firstMissing(
            classAvailable: { classes[$0] != nil },
            setterAvailable: hasSetter,
            backdrop: false
        )
    }

    static func firstMissing(
        classAvailable: (String) -> Bool,
        setterAvailable: (String, String) -> Bool,
        backdrop: Bool = true
    ) -> String? {
        for name in backdrop ? classNames : sdfClassNames where !classAvailable(name) { return "\(name).class" }
        var requirements = backdrop ? [("CABackdropLayer", BackdropProperty.allCases.map(\.rawValue))] : []
        requirements += [
            ("CASDFLayer", BodyProperty.allCases.map(\.rawValue)),
            ("CASDFElementLayer", ElementProperty.allCases.map(\.rawValue))
        ]
        requirements += Effect.allCases.map { ($0.rawValue, $0.keys.map(\.rawValue)) }
        for (name, keys) in requirements {
            for key in keys where !setterAvailable(name, key) { return "\(name).\(key)" }
        }
        return nil
    }

    func effect(_ effect: Effect, values: [EffectKey: Any]) -> NSObject? {
        guard flatMissing == nil, let type = effectClasses[effect] else { return nil }
        let keys = effect.keys
        precondition(keys.count == values.count)
        let result = type.init()
        for key in keys {
            guard let value = values[key] else { preconditionFailure("\(effect.rawValue).\(key.rawValue)") }
            result.setValue(value, forKey: key.rawValue)
        }
        return result
    }

    func compositing(_ mode: Compositing) -> NSObject? {
        guard flatMissing == nil else { return nil }
        return filterClass?.perform(NSSelectorFromString("filterWithType:"), with: mode.rawValue)?
            .takeUnretainedValue() as? NSObject
    }
}
