// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import OmniWMShellCore

final class Probe {
    var value = 0
}

@main
enum ArcAudit {
    static let cycles = 10000
    static let measure: MeasureText = { _, text, _, _, _, width, height in
        width.pointee = Float(8 + text % 5)
        height.pointee = 12
    }

    static func tree(variant: Int) -> UnsafeBufferPointer<TreeNode> {
        var nodes = [TreeNode(kind: .group, subtreeEnd: 50, key: 1, layout: LayoutStyle(gap: 4, padding: 2))]
        for index in 1 ..< 50 {
            let changed = variant == 1 && [3, 10, 20, 31, 44].contains(index)
            let key = UInt64(index + 1)
            if index % 2 == 0 {
                nodes.append(TreeNode(
                    kind: .label,
                    subtreeEnd: Int32(index + 1),
                    key: key,
                    content: Content(text: UInt32(changed ? index + 100 : index), action: UInt32(index))
                ))
            } else {
                nodes.append(TreeNode(
                    kind: .box,
                    subtreeEnd: Int32(index + 1),
                    key: key,
                    layout: LayoutStyle(width: changed ? 14 : 10, height: 10),
                    paint: Paint(fill: Color(red: changed ? 1 : 0, green: 0.5, blue: 0, alpha: 1))
                ))
            }
        }
        let buffer = UnsafeMutableBufferPointer<TreeNode>.allocate(capacity: nodes.count)
        _ = buffer.initialize(from: nodes)
        return UnsafeBufferPointer(buffer)
    }

    static func main() {
        arc_audit_install()
        let first = tree(variant: 0)
        let second = tree(variant: 1)
        var core = SurfaceCore(capacity: 128)
        var patches = PatchBuffer(capacity: 256)
        var hits = 0
        func cycle(_ index: Int) {
            patches.removeAll()
            core.apply(index & 1 == 0 ? first : second, measure: measure, context: nil, into: &patches)
            let x = Float(index % 400)
            if core.covers(x: x, y: 6, where: { core.kind(of: $0) == .box }) {
                hits += 1
            }
            if core.hitTest(x: x, y: 6, matching: { $0.action != 0 }).slot >= 0 {
                hits += 1
            }
            core.setRootBleed(Insets(top: Float(index & 1)), into: &patches)
        }
        for index in 0 ..< 2000 {
            cycle(index)
        }

        arc_audit_start()
        let probe = Unmanaged.passRetained(Probe())
        let buffer = strdup("arc-audit")
        arc_audit_stop()
        probe.takeUnretainedValue().value = Int(bitPattern: buffer)
        probe.release()
        free(buffer)
        guard arc_audit_allocations() > 0, arc_audit_mallocs() > 0 else {
            print(
                "arc-audit: the counters missed a known allocation (Swift \(arc_audit_allocations()), malloc \(arc_audit_mallocs())); the measurement is not valid"
            )
            exit(2)
        }

        arc_audit_start()
        for index in 0 ..< cycles {
            cycle(index)
        }
        arc_audit_stop()
        let counts = [
            ("swift_retain", arc_audit_retains()),
            ("swift_release", arc_audit_releases()),
            ("swift_allocObject", arc_audit_allocations()),
            ("malloc", arc_audit_mallocs())
        ]
        print("arc-audit: \(cycles) steady-state cycles of a 50-node apply, covers, hitTest and bleed (\(hits) hits)")
        for (name, count) in counts {
            print("  \(name): \(count)")
        }
        exit(counts.allSatisfy { $0.1 == 0 } ? 0 : 1)
    }
}
