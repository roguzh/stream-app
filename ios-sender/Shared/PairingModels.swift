import Foundation

// Written by the extension to the App Group container once the offer + non-trickle
// ICE gathering are ready; read by the main app to render the QR/manual-entry code.
struct PairingSession: Codable, Equatable {
    let sessionId: String
    let offerSdp: String
    let ip: String
    let port: UInt16
    let createdAt: Date
    let expiresAt: Date

    var pairingURLString: String {
        "http://\(ip):\(port)\(AppConstants.signalingPathOffer)?sid=\(sessionId)"
    }

    // For the receiver's two-field manual entry (address + code) — the address
    // portion is stable enough to remember across sessions; only the code changes.
    var addressString: String {
        "\(ip):\(port)"
    }
}

// Short, human-typeable codes instead of a 36-character UUID — this is a LAN
// pairing code, not a security credential (STREAM_PASSWORD-equivalent security
// doesn't exist for the serverless iOS path at all yet), so a short alphabet is
// fine. Excludes visually ambiguous characters (0/O, 1/I).
enum PairingCode {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generate(length: Int = 6) -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

// Wire format for the one-shot GET /offer response and POST /answer request —
// shared verbatim with what receiver.html expects/sends (see public/receiver.html).
struct SDPPayload: Codable {
    let type: String // "offer" or "answer"
    let sdp: String
}

enum PairingState: Equatable {
    case idle
    case waitingForBroadcastStart
    case waitingForOffer
    case ready(PairingSession)
    case receiverConnected
    case timedOut
    case stopped
}
