import StreamWebRTC
import AVFoundation

// Owns the RTCPeerConnection for the whole broadcast session — capture, encode,
// and RTP send all happen in this (the extension) process; see "Where the peer
// connection lives" in the project plan for why. Several calls below are marked
// VERIFY: best-effort based on the standard WebRTC iOS API shape, not confirmed
// against actual StreamWebRTC 148.0.0 headers (no Xcode available while writing
// this) — Cmd-click into each before trusting it.
final class WebRTCSessionManager: NSObject {
    enum SessionError: Error {
        case peerConnectionCreationFailed
    }

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer? // Reused across frames — see captureVideoFrame.
    let audioDeviceModule = CustomAudioDeviceModule()

    private var iceGatheringCompletion: ((String) -> Void)?
    private var iceGatheringTimeoutWorkItem: DispatchWorkItem?

    override init() {
        RTCInitializeSSL()
        let encoderFactory = H264OnlyEncoderFactory()
        let decoderFactory = H264OnlyDecoderFactory()

        // VERIFY: exact initializer for supplying a custom RTCAudioDevice — this is
        // the whole reason CustomAudioDeviceModule exists (see its file header).
        // Recent WebRTC iOS SDKs added an initializer along these lines specifically
        // to support ReplayKit broadcast-extension screen share; confirm the exact
        // parameter list/name in StreamWebRTC's RTCPeerConnectionFactory.h.
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioDevice: audioDeviceModule
        )
        super.init()
    }

    /// Builds the peer connection, adds send-only video/audio transceivers with the
    /// quality params already fixed in the web/Android siblings, creates the offer,
    /// waits for non-trickle ICE gathering to complete, and hands back the final SDP.
    func setUp(completion: @escaping (Result<String, Error>) -> Void) {
        let config = RTCConfiguration()
        config.iceServers = [] // LAN only, matches the web/Android siblings' iceServers: [].
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            completion(.failure(SessionError.peerConnectionCreationFailed))
            return
        }
        peerConnection = pc

        let source = factory.videoSource()
        // No iOS equivalent to the web sender's contentHint = 'motion' — this
        // SDK's RTCVideoSource/RTCMediaSource expose no such property (verified
        // against the actual header; there's no isScreencast or similar here).
        // Quality-under-motion has to come from degradationPreference/bitrate
        // tuning on the sender instead, same as the fallback path the browser
        // sender already relies on when contentHint itself doesn't help enough.
        videoSource = source
        videoCapturer = RTCVideoCapturer(delegate: source)

        let videoTrack = factory.videoTrack(with: source, trackId: "video0")
        if let videoTransceiver = pc.addTransceiver(with: videoTrack, init: sendOnlyInit()) {
            H264CodecFactory.applyCodecPreference(to: videoTransceiver, factory: factory)
        }

        // Audio data delivery bypasses the normal source/capturer path entirely —
        // it goes through CustomAudioDeviceModule's delegate callback instead. This
        // track is mainly a logical handle for SDP negotiation.
        let audioTrack = factory.audioTrack(withTrackId: "audio0")
        pc.addTransceiver(with: audioTrack, init: sendOnlyInit())

        applyQualityParams(peerConnection: pc)

        iceGatheringCompletion = { sdp in completion(.success(sdp)) }
        createOfferAndWaitForIceGathering(peerConnection: pc)
    }

    private func sendOnlyInit() -> RTCRtpTransceiverInit {
        let initOptions = RTCRtpTransceiverInit()
        initOptions.direction = .sendOnly
        return initOptions
    }

    private func createOfferAndWaitForIceGathering(peerConnection: RTCPeerConnection) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp else {
                NSLog("WebRTCSessionManager: createOffer failed: \(String(describing: error))")
                return
            }
            // Mirrors enhanceOpusAudio() in sender.html — munge before setLocalDescription.
            let munged = RTCSessionDescription(type: sdp.type, sdp: SDPMunging.enhanceOpusAudio(sdp.sdp))
            peerConnection.setLocalDescription(munged) { error in
                if let error {
                    NSLog("WebRTCSessionManager: setLocalDescription failed: \(error)")
                    return
                }
                // Non-trickle: wait for RTCPeerConnectionDelegate's ICE-gathering-state
                // callback (below) to report .complete before handing off the SDP —
                // by then it has every host candidate embedded inline.
                self.armIceGatheringTimeout(peerConnection: peerConnection)
            }
        }
    }

    private func armIceGatheringTimeout(peerConnection: RTCPeerConnection) {
        // Defensive safety net only — not expected to trigger under normal
        // iceServers:[] LAN gathering, which should complete in well under a second.
        let work = DispatchWorkItem { [weak self] in
            self?.finishIceGathering(peerConnection: peerConnection)
        }
        iceGatheringTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    fileprivate func finishIceGathering(peerConnection: RTCPeerConnection) {
        iceGatheringTimeoutWorkItem?.cancel()
        guard let localDescription = peerConnection.localDescription else { return }
        iceGatheringCompletion?(localDescription.sdp)
        iceGatheringCompletion = nil
    }

    private func applyQualityParams(peerConnection: RTCPeerConnection) {
        for sender in peerConnection.senders {
            guard let track = sender.track else { continue }
            let params = sender.parameters
            guard !params.encodings.isEmpty else { continue }

            // VERIFY: exact property name for RTP priority on RTCRtpEncodingParameters
            // — the concept (audio must not default to lower priority than video, or
            // it gets starved under congestion first) is the exact bug already found
            // and fixed on web/Android; do not reintroduce it here even if this
            // specific property name needs adjusting.
            params.encodings[0].networkPriority = .high

            if track.kind == kRTCMediaStreamTrackKindVideo {
                params.encodings[0].maxBitrateBps = NSNumber(value: AppConstants.videoBitrateBps)
                params.encodings[0].maxFramerate = NSNumber(value: AppConstants.maxFramerate)
                params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerate.rawValue)
            } else if track.kind == kRTCMediaStreamTrackKindAudio {
                params.encodings[0].maxBitrateBps = NSNumber(value: AppConstants.audioBitrateBps)
            }

            sender.parameters = params
        }
    }

    // MARK: - Feeding captured media (called from SampleHandler)

    private var loggedFirstCapturedFrame = false

    func captureVideoFrame(pixelBuffer: CVPixelBuffer, timestampNs: Int64, rotation: RTCVideoRotation = ._0) {
        guard let videoSource, let videoCapturer else {
            AppGroupStore.logDiagnostic("captureVideoFrame: videoSource or videoCapturer is nil, dropping frame")
            return
        }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: rotation, timeStampNs: timestampNs)
        videoSource.capturer(videoCapturer, didCapture: frame)
        if !loggedFirstCapturedFrame {
            loggedFirstCapturedFrame = true
            AppGroupStore.logDiagnostic("captureVideoFrame: pushed first frame to videoSource successfully")
        }
    }

    func captureAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        audioDeviceModule.deliverCapturedPCM(sampleBuffer: sampleBuffer)
    }

    // MARK: - Answer handling

    func applyAnswer(_ payload: SDPPayload, completion: @escaping (Error?) -> Void) {
        guard let peerConnection else { return }
        let description = RTCSessionDescription(type: .answer, sdp: payload.sdp)
        peerConnection.setRemoteDescription(description, completionHandler: completion)
    }

    func close() {
        peerConnection?.close()
        peerConnection = nil
        RTCCleanupSSL()
    }
}

extension WebRTCSessionManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // Diagnostic only — mirrors the reentrancy hazard noted below, so hop off
        // the signaling thread before touching AppGroupStore/file I/O.
        DispatchQueue.main.async {
            AppGroupStore.logDiagnostic("ICE connection state changed: \(newState.rawValue)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // This delegate method fires synchronously on WebRTC's own signaling
        // thread (confirmed via a device crash: SIGABRT inside this exact call
        // chain, thread named "signaling_thread"). finishIceGathering reads
        // peerConnection.localDescription and kicks off further work (writing
        // to the App Group, starting the NWListener) — calling back into
        // RTCPeerConnection and doing that work synchronously from within its
        // own delegate callback hits an internal WebRTC reentrancy assertion.
        // Hop off the signaling thread first.
        if newState == .complete {
            DispatchQueue.main.async { [weak self] in
                self?.finishIceGathering(peerConnection: peerConnection)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Non-trickle by design — candidates are read from localDescription once
        // gathering completes, not relayed individually. Nothing to do here.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
