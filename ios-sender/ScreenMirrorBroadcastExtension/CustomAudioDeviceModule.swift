import AVFoundation
import StreamWebRTC

// HIGHEST-RISK FILE IN THIS PROJECT — see Risk #2 in the project plan
// (~/.claude/plans/moonlit-churning-mccarthy.md). WebRTC's iOS SDK has no direct
// "push a CMSampleBuffer" ingestion point for audio the way video has
// RTCCVPixelBuffer. The supported mechanism is implementing the RTCAudioDevice
// protocol and delivering PCM through its delegate, bypassing the default
// AVAudioSession-based ADM entirely — which we don't want anyway, since a
// Broadcast Extension can't freely drive AVAudioSession, and ReplayKit is already
// handing us sample buffers for both app and mic audio.
//
// VERIFY BEFORE RELYING ON THIS FILE: Cmd-click into `RTCAudioDevice` and
// `RTCAudioDeviceDelegate` in Xcode and confirm every method name/signature below
// actually matches what StreamWebRTC 148.0.0 declares. This is the single most
// version-sensitive corner of the iOS WebRTC SDK — the shape here (lifecycle
// methods, AudioBufferList-based delivery mirroring a CoreAudio render callback)
// matches the general pattern real RTCAudioDevice implementations use, but exact
// selectors can differ by SDK version. Build and validate this file in isolation —
// confirm a receiver can actually hear custom-injected PCM — before wiring up the
// rest of the capture pipeline on the assumption it works as written.
final class CustomAudioDeviceModule: NSObject, RTCAudioDevice {

    private weak var audioDelegate: RTCAudioDeviceDelegate?
    private(set) var isInitialized = false
    private var isRecording = false

    // WebRTC's ADM expects a fixed format and does not resample for you — mixed
    // app+mic PCM handed to deliverCapturedPCM must already be in this format.
    let captureSampleRate: Double = 48_000
    let captureChannels: UInt32 = 2

    var inputIsAvailable: Bool { true }
    var outputIsAvailable: Bool { false } // No local playout needed — the extension has no speaker output.

    // MARK: - RTCAudioDevice lifecycle

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        audioDelegate = delegate
        isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        isInitialized = false
        audioDelegate = nil
        return true
    }

    func initializeCapture() -> Bool { true }

    func startCapture() -> Bool {
        isRecording = true
        return true
    }

    func stopCapture() -> Bool {
        isRecording = false
        return true
    }

    // No real playout device in the extension — stub these out as no-ops.
    func initializePlayout() -> Bool { true }
    func startPlayout() -> Bool { false }
    func stopPlayout() -> Bool { true }

    // MARK: - Feeding audio in

    /// Call from SampleHandler.processSampleBuffer for both .audioApp and .audioMic
    /// sample types, after mixing them into one PCM stream at captureSampleRate/
    /// captureChannels (resample upstream if ReplayKit hands you a different format).
    func deliverCapturedPCM(sampleBuffer: CMSampleBuffer) {
        guard isRecording, let audioDelegate else { return }

        var audioBufferList = AudioBufferList()
        var blockBufferOut: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBufferOut
        )
        guard status == noErr else {
            NSLog("CustomAudioDeviceModule: failed to extract AudioBufferList, status \(status)")
            return
        }

        let timestampSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        // VERIFY: exact delegate selector — see file header. This is a best-effort
        // name based on the standard RTCAudioDevice integration pattern.
        audioDelegate.deliverRecordedData?(audioBufferList, timestamp: timestampSeconds)
    }
}
