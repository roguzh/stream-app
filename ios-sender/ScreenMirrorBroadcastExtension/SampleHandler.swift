import ReplayKit
import StreamWebRTC

final class SampleHandler: RPBroadcastSampleHandler {
    private let sessionManager = WebRTCSessionManager()
    private var signalingListener: SignalingListener?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let sessionId = UUID().uuidString

        sessionManager.setUp { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sdp):
                self.startSignaling(sessionId: sessionId, offerSdp: sdp)
            case .failure(let error):
                NSLog("SampleHandler: WebRTC setup failed: \(error)")
                self.finishBroadcastWithError(error)
            }
        }
    }

    private func startSignaling(sessionId: String, offerSdp: String) {
        guard let ip = LANAddress.currentIPv4() else {
            NSLog("SampleHandler: could not determine LAN IP")
            finishBroadcastWithError(SessionSetupError.noLANAddress)
            return
        }

        // Port is filled in once the listener actually binds (onReady) — the
        // pairing session is only written to the App Group at that point, so the
        // main app never sees a session referencing port 0.
        let now = Date()
        let pendingSession = PairingSession(
            sessionId: sessionId, offerSdp: offerSdp, ip: ip, port: 0,
            createdAt: now, expiresAt: now.addingTimeInterval(60)
        )

        let listener = SignalingListener(session: pendingSession)

        listener.onReady = { port in
            let readySession = PairingSession(
                sessionId: pendingSession.sessionId,
                offerSdp: pendingSession.offerSdp,
                ip: pendingSession.ip,
                port: port,
                createdAt: pendingSession.createdAt,
                expiresAt: pendingSession.expiresAt
            )
            AppGroupStore.writePairingSession(readySession)
            DarwinNotifications.post(AppConstants.DarwinNotification.offerReady)
        }

        listener.onAnswerReceived = { [weak self] payload in
            self?.sessionManager.applyAnswer(payload) { error in
                if let error {
                    NSLog("SampleHandler: applyAnswer failed: \(error)")
                }
            }
        }

        listener.onTimeout = { [weak self] in
            DarwinNotifications.post(AppConstants.DarwinNotification.pairingTimedOut)
            self?.finishBroadcastWithError(SessionSetupError.pairingTimedOut)
        }

        signalingListener = listener
        do {
            try listener.start()
        } catch {
            NSLog("SampleHandler: signaling listener failed to start: \(error)")
            finishBroadcastWithError(error)
        }
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        signalingListener?.stop()
        sessionManager.close()
        AppGroupStore.clearPairingSession()
        DarwinNotifications.post(AppConstants.DarwinNotification.broadcastStopped)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let timestampNs = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
            sessionManager.captureVideoFrame(pixelBuffer: pixelBuffer, timestampNs: timestampNs)
        case .audioApp, .audioMic:
            sessionManager.captureAudioSampleBuffer(sampleBuffer)
        @unknown default:
            break
        }
    }
}

enum SessionSetupError: Error {
    case noLANAddress
    case pairingTimedOut
}
