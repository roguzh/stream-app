import StreamWebRTC

// Mirrors sender.html's H.264-forcing strategy: encoder/decoder factories filtered
// to H.264 only, plus explicit RTCRtpTransceiver.setCodecPreferences() so the
// browser/receiver never has to guess at codec negotiation.
final class H264OnlyEncoderFactory: RTCDefaultVideoEncoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        super.supportedCodecs()
            .filter { $0.name == kRTCVideoCodecH264Name }
            .sorted { H264CodecFactory.profileRank($0) < H264CodecFactory.profileRank($1) }
    }
}

final class H264OnlyDecoderFactory: RTCDefaultVideoDecoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        super.supportedCodecs()
            .filter { $0.name == kRTCVideoCodecH264Name }
            .sorted { H264CodecFactory.profileRank($0) < H264CodecFactory.profileRank($1) }
    }
}

enum H264CodecFactory {
    // Mirrors h264ProfileRank() in sender.html: High > Main > Baseline, decoded
    // from profile-level-id's first byte.
    static func profileRank(_ codec: RTCVideoCodecInfo) -> Int {
        guard let profileLevelId = codec.parameters["profile-level-id"] else { return 99 }
        switch String(profileLevelId.prefix(2)).lowercased() {
        case "64": return 0 // High
        case "4d": return 1 // Main
        case "42": return 2 // Baseline
        default: return 50
        }
    }

    // Mirrors setH264CodecPreference() in sender.html — call after addTransceiver,
    // before creating the offer.
    static func applyCodecPreference(to transceiver: RTCRtpTransceiver) {
        guard let capabilities = RTCRtpSender.senderCapabilities(forKind: kRTCMediaStreamTrackKindVideo) else { return }
        let h264 = capabilities.codecs
            .filter { $0.name == kRTCVideoCodecH264Name }
            .sorted { profileRank($0) < profileRank($1) }
        guard !h264.isEmpty else { return }
        let rest = capabilities.codecs.filter { $0.name != kRTCVideoCodecH264Name }
        transceiver.setCodecPreferences(h264 + rest)
    }
}
