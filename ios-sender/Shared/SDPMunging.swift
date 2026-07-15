import Foundation

// Pure string-level SDP munging, faithfully ported from the same techniques in
// public/sender.html — keep the two in sync if the tuning parameters ever change.
// H.264 codec *preference* (as opposed to this file's Opus fmtp munging) is done
// via RTCRtpTransceiver.setCodecPreferences with RTCRtpCodecCapability objects,
// not string munging — see H264CodecFactory.swift in the extension target.
enum SDPMunging {
    // Opus defaults are tuned for voice calls, not screen/movie audio: DTX (silence
    // suppression) creates audible gaps in anything that isn't a voice call, and
    // without in-band FEC a single lost Wi-Fi packet drops a chunk of audio outright
    // instead of being reconstructed. Mirrors enhanceOpusAudio() in sender.html.
    static func enhanceOpusAudio(_ sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        let rtpmapRegex = try! NSRegularExpression(pattern: #"^a=rtpmap:(\d+) opus/48000"#)

        var opusPayload: String?
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = rtpmapRegex.firstMatch(in: line, range: range),
               let payloadRange = Range(match.range(at: 1), in: line) {
                opusPayload = String(line[payloadRange])
                break
            }
        }

        guard let payload = opusPayload else { return sdp }

        let fmtpParams = "minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1;usedtx=0;maxaveragebitrate=\(AppConstants.audioBitrateBps)"
        let fmtpPrefix = "a=fmtp:\(payload) "
        var foundFmtp = false

        for i in lines.indices where lines[i].hasPrefix(fmtpPrefix) {
            lines[i] = fmtpPrefix + fmtpParams
            foundFmtp = true
        }

        if !foundFmtp {
            let rtpmapPrefix = "a=rtpmap:\(payload) opus/48000"
            if let idx = lines.firstIndex(where: { $0.hasPrefix(rtpmapPrefix) }) {
                lines.insert(fmtpPrefix + fmtpParams, at: idx + 1)
            }
        }

        return lines.joined(separator: "\r\n")
    }
}
