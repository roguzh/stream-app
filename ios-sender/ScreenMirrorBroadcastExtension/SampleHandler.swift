import ReplayKit
import StreamWebRTC

final class SampleHandler: RPBroadcastSampleHandler {
    private let sessionManager = WebRTCSessionManager()
    private var signalingListener: SignalingListener?

    // Diagnostic-only counters, throttled to avoid disk/CPU overhead at 30-60fps —
    // see AppGroupStore.logDiagnostic's doc comment for why this exists.
    private var videoFrameCount = 0
    private var audioAppFrameCount = 0
    private var audioMicFrameCount = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        AppGroupStore.clearDiagnosticLog()
        AppGroupStore.logDiagnostic("broadcastStarted called")
        let sessionId = UUID().uuidString

        sessionManager.setUp { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sdp):
                AppGroupStore.logDiagnostic("sessionManager.setUp succeeded, sdp length \(sdp.count)")
                self.startSignaling(sessionId: sessionId, offerSdp: sdp)
            case .failure(let error):
                NSLog("SampleHandler: WebRTC setup failed: \(error)")
                AppGroupStore.logDiagnostic("sessionManager.setUp FAILED: \(error)")
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
            // Matches SignalingListener's actual timeout — kept in sync since
            // this is metadata only right now, not enforced anywhere itself.
            createdAt: now, expiresAt: now.addingTimeInterval(180)
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
            AppGroupStore.logDiagnostic("onAnswerReceived called, sdp length \(payload.sdp.count)")
            self?.sessionManager.applyAnswer(payload) { error in
                if let error {
                    NSLog("SampleHandler: applyAnswer failed: \(error)")
                    AppGroupStore.logDiagnostic("applyAnswer FAILED: \(error)")
                } else {
                    AppGroupStore.logDiagnostic("applyAnswer succeeded")
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
            videoFrameCount += 1
            if videoFrameCount == 1 {
                AppGroupStore.logDiagnostic("first .video sample buffer received")
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                AppGroupStore.logDiagnostic("video frame \(videoFrameCount): CMSampleBufferGetImageBuffer returned nil")
                return
            }
            if videoFrameCount % 60 == 1 {
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                AppGroupStore.logDiagnostic("video frame \(videoFrameCount): \(w)x\(h)")
            }
            let timestampNs = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
            sessionManager.captureVideoFrame(pixelBuffer: pixelBuffer, timestampNs: timestampNs)
        case .audioApp:
            audioAppFrameCount += 1
            if audioAppFrameCount == 1 {
                AppGroupStore.logDiagnostic("first .audioApp sample buffer received")
            }
            sessionManager.captureAudioSampleBuffer(sampleBuffer)
        case .audioMic:
            audioMicFrameCount += 1
            if audioMicFrameCount == 1 {
                AppGroupStore.logDiagnostic("first .audioMic sample buffer received")
            }
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
