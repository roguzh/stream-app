import Foundation
import StreamWebRTC

// Mirrors sender.html's H.264-forcing strategy: encoder/decoder factories filtered
// to H.264 only, plus explicit RTCRtpTransceiver.setCodecPreferences() so the
// browser/receiver never has to guess at codec negotiation.
final class H264OnlyEncoderFactory: RTCDefaultVideoEncoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        super.supportedCodecs()
            .filter { $0.name == kRTCVideoCodecH264Name }
            .sorted { H264CodecFactory.profileRank($0.parameters) < H264CodecFactory.profileRank($1.parameters) }
    }
}

final class H264OnlyDecoderFactory: RTCDefaultVideoDecoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        super.supportedCodecs()
            .filter { $0.name == kRTCVideoCodecH264Name }
            .sorted { H264CodecFactory.profileRank($0.parameters) < H264CodecFactory.profileRank($1.parameters) }
    }
}

enum H264CodecFactory {
    // Mirrors h264ProfileRank() in sender.html: High > Main > Baseline, decoded
    // from profile-level-id's first byte. Takes the raw parameters dictionary
    // rather than a codec object because RTCVideoCodecInfo (used by the
    // encoder/decoder factories) and RTCRtpCodecCapability (used by
    // setCodecPreferences) are different, unrelated types in this SDK that
    // happen to both expose an identically-shaped `.parameters` dictionary.
    static func profileRank(_ parameters: [String: String]) -> Int {
        guard let profileLevelId = parameters["profile-level-id"] else { return 99 }
        switch String(profileLevelId.prefix(2)).lowercased() {
        case "64": return 0 // High
        case "4d": return 1 // Main
        case "42": return 2 // Baseline
        default: return 50
        }
    }

    // Mirrors setH264CodecPreference() in sender.html — call after addTransceiver,
    // before creating the offer. Capabilities come from the peer connection
    // factory (RTCRtpSender has no static capabilities lookup in this SDK,
    // unlike what the name might suggest by analogy with the browser API).
    static func applyCodecPreference(to transceiver: RTCRtpTransceiver, factory: RTCPeerConnectionFactory) {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        let h264 = capabilities.codecs
            .filter { $0.name == kRTCVideoCodecH264Name }
            .sorted { profileRank($0.parameters) < profileRank($1.parameters) }
        guard !h264.isEmpty else { return }
        let rest = capabilities.codecs.filter { $0.name != kRTCVideoCodecH264Name }
        do {
            try transceiver.setCodecPreferences(h264 + rest, error: ())
        } catch {
            NSLog("H264CodecFactory: setCodecPreferences failed: \(error)")
        }
    }
}
