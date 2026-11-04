// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriEdgePictures {
    static let minimumLivePictureHeight: CGFloat = 5

    func reconcileLiveStreams() {
        guard let prepareStream else { return }
        let suspended = isOverviewOpen() || isUnderMemoryPressure
        for (token, picture) in pictures {
            guard !suspended, isCaptureEligible(token) else {
                picture.stream?.stop()
                picture.stream = nil
                continue
            }
            guard picture.isResting else { continue }
            guard isVisibleForStreaming(picture) else {
                picture.stream?.stop()
                picture.stream = nil
                continue
            }
            let request = NiriPictureStreamSession.Request(
                token: token, size: picture.geometry.frame.size, scale: picture.scale
            )
            if picture.stream?.request != request {
                picture.stream?.stop()
                let session = NiriPictureStreamSession(request: request)
                picture.stream = session
                prepareLiveStream(session, picture: picture, prepare: prepareStream)
            }
            guard let session = picture.stream else { continue }
            scheduleStreamStart(session, picture: picture)
            deliverStreamFrame(session, picture: picture)
        }
    }

    private func prepareLiveStream(
        _ session: NiriPictureStreamSession,
        picture: Picture,
        prepare: NiriPictureStreamSession.Prepare
    ) {
        let output = OverviewPreviewStream(
            onReady: { [weak self, weak session, weak picture] in
                Task { @MainActor in
                    guard let self, let session, let picture else { return }
                    self.deliverStreamFrame(session, picture: picture)
                }
            },
            onFailure: { [weak self, weak session, weak picture] in
                Task { @MainActor in
                    guard let self, let session, let picture else { return }
                    self.streamFailed(session, picture: picture)
                }
            }
        )
        session.output = output
        session.preparation = prepare(session.request, output) { [weak self, weak session, weak picture] build in
            guard let self, let session, let picture, isCurrentStream(session, picture: picture) else { return }
            session.preparation = nil
            guard let build else { session.stop(failed: true)
                return
            }
            session.phase = .ready(build)
            scheduleStreamStart(session, picture: picture)
        }
    }

    private func scheduleStreamStart(_ session: NiriPictureStreamSession, picture: Picture) {
        guard session.startTask == nil, case let .ready(build) = session.phase,
              canPresentStream(session, picture: picture) else { return }
        session.startTask = Task { @MainActor [weak self, weak picture, weak session] in
            guard let session, let picture else { return }
            guard !Task.isCancelled, case .ready = session.phase,
                  self?.canPresentStream(session, picture: picture) == true
            else {
                session.startTask = nil
                return
            }
            do {
                session.phase = .starting
                let control = try build()
                session.control = control
                try await control.start()
                guard self?.isCurrentStream(session, picture: picture) == true,
                      case .starting = session.phase
                else { control.stop()
                    return
                }
                session.startTask = nil
                session.phase = .running
                self?.deliverStreamFrame(session, picture: picture)
            } catch {
                ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
                guard self?.isCurrentStream(session, picture: picture) == true,
                      case .starting = session.phase else { return }
                session.stop(failed: true)
            }
        }
    }

    func streamFailed(_ session: NiriPictureStreamSession, picture: Picture) {
        guard isCurrentStream(session, picture: picture) else { return }
        session.stop(failed: true)
    }

    func deliverStreamFrame(_ session: NiriPictureStreamSession, picture: Picture) {
        guard canPresentStream(session, picture: picture), let frame = session.output?.take() else { return }
        picture.content = .preview(frame)
        picture.surface?.setContent(.preview(frame))
    }

    private func isCurrentStream(_ session: NiriPictureStreamSession, picture: Picture) -> Bool {
        pictures[session.request.token] === picture && picture.stream === session
    }

    private func canPresentStream(_ session: NiriPictureStreamSession, picture: Picture) -> Bool {
        isCurrentStream(session, picture: picture) && picture.isResting
            && isVisibleForStreaming(picture) && !isOverviewOpen() && !isUnderMemoryPressure
            && isCaptureEligible(session.request.token)
    }

    private func isVisibleForStreaming(_ picture: Picture) -> Bool {
        picture.geometry.visibleFrame.height >= Self.minimumLivePictureHeight
            && picture.surface?.isVisibleForCapture == true
    }
}
