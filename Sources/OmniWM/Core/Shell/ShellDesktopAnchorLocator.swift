// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost
import OmniWMShellCore

struct ShellDesktopAnchorLocator: Equatable, Sendable {
    let epoch: UInt64
    let unit: UInt64
    let key: UInt64

    init(bytes: [UInt8]) throws {
        guard bytes.count == MemoryLayout<omni_desktop_anchor>.size
        else { throw ShellResourceFailure("invalid_anchor") }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: omni_desktop_anchor.self) }
        epoch = value.epoch
        unit = value.unit
        key = value.key
    }

    var wire: omni_desktop_anchor {
        omni_desktop_anchor(epoch: epoch, unit: unit, key: key)
    }
}

struct ShellDesktopAnchorResolution: Sendable {
    let sequence: Int
    let path: [ElementPathStep]
}

extension ShellWidgetPackage {
    func resolveDesktopAnchor(
        _ locator: ShellDesktopAnchorLocator,
        owner: ShellServiceOwner,
        origin: ShellDesktopOrigin
    ) throws -> ShellDesktopAnchorResolution {
        guard !closing, owner.generation == services.generation, origin.widget == name, origin.generation == generation,
              origin.sourceID != 0, let script, let instance = script.instances[origin.key.bar],
              let state = states[origin.key.bar] else { throw ShellResourceFailure("anchor_unavailable") }
        var steps = [omni_anchor_step](repeating: omni_anchor_step(), count: 65)
        var count = 0
        var error = [CChar](repeating: 0, count: 256)
        let status = steps.withUnsafeMutableBufferPointer {
            omni_instance_resolve_anchor(
                instance,
                origin.key.view.wire,
                owner.wire,
                locator.wire,
                $0.baseAddress,
                $0.count,
                &count,
                &error,
                error.count
            )
        }
        guard status == OMNI_OK else {
            throw ShellResourceFailure(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        let path = try steps.prefix(count).map { step in
            guard let kind = ElementKind(rawValue: UInt8(exactly: step.kind) ?? .max) else {
                throw ShellResourceFailure("invalid_anchor")
            }
            return ElementPathStep(kind: kind, key: step.key, child: Int(step.child))
        }
        return ShellDesktopAnchorResolution(sequence: state.sequences[origin.key.view.rawValue], path: path)
    }
}
