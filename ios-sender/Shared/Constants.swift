import Foundation

// If you change PRODUCT_BUNDLE_IDENTIFIER or bundleIdPrefix in project.yml,
// update these to match — nothing derives them automatically.
enum AppConstants {
    static let appGroupID = "group.com.streamapp.screenmirror"
    static let broadcastExtensionBundleID = "com.streamapp.iossender.broadcast"

    static let bonjourServiceType = "_screenmirror._tcp"
    static let signalingPathOffer = "/offer"
    static let signalingPathAnswer = "/answer"
    // Fixed instead of ephemeral (.any) — a random port every session meant even
    // remembering the sender's IP didn't help, the port always changed too. Only
    // the short pairing code needs to be freshly typed now; the address is stable
    // enough for the receiver to remember it.
    static let signalingPort: UInt16 = 8990

    // Codec/bitrate constants mirrored from public/sender.html's QUALITY_PRESETS
    // and AUDIO_BITRATE, kept here so both targets reference one source of truth.
    static let videoBitrateBps: UInt = 20_000_000
    static let audioBitrateBps: UInt = 128_000
    static let maxFramerate: UInt = 30 // ReplayKit captures at up to 30fps; see SampleHandler notes.

    enum DarwinNotification {
        static let offerReady = "com.streamapp.iossender.offerReady"
        static let pairingTimedOut = "com.streamapp.iossender.pairingTimedOut"
        static let broadcastStopped = "com.streamapp.iossender.broadcastStopped"
    }

    static let pairingFileName = "pairing.json"
}
