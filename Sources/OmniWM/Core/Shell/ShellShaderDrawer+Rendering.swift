// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Metal

extension ShellShaderDrawer {
    struct Frame: Sendable {
        let slot: Int32
        let token: Int
        let index: Int
        let program: ShellShaderProgram
        let revision: Int
        let failure: String?
        let duration: Double
        var lease: ShellGroupEffectBudget.Lease?
        var sourceDuration: Double = 0
        var totalDuration: Double = 0
    }

    static func complete(
        _ buffer: any MTLCommandBuffer, submitted: Frame,
        timing: ShellGroupEffectTiming?, completion: @escaping Completion
    ) {
        let failure = buffer.status == .error ? buffer.error?.localizedDescription ?? "the GPU reported an error" : nil
        let end = buffer.gpuEndTime
        let start = buffer.gpuStartTime
        let frame = Frame(
            slot: submitted.slot, token: submitted.token, index: submitted.index,
            program: submitted.program, revision: submitted.revision,
            failure: failure, duration: end - start, lease: submitted.lease, totalDuration: end - start
        )
        if let timing {
            timing.finish { sample in
                completion(Frame(
                    slot: frame.slot, token: frame.token, index: frame.index, program: frame.program,
                    revision: frame.revision,
                    failure: failure ?? sample.failure, duration: frame.duration, lease: frame.lease,
                    sourceDuration: sample.end > 0 ? sample.end - sample.start : 0,
                    totalDuration: end - (sample.start > 0 ? sample.start : start)
                ))
            }
        } else {
            completion(frame)
        }
    }

    static func pass(into texture: any MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    static func rate(input: ShellShaderInput, neutral: Bool, sourceRate: Int) -> Int {
        max(neutral ? 0 : input.rate, sourceRate)
    }
}
