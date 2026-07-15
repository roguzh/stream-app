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
