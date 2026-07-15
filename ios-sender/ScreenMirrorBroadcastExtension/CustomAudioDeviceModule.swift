import AVFoundation
import StreamWebRTC

// Custom RTCAudioDevice implementation: WebRTC's iOS SDK has no direct "push a
// CMSampleBuffer" ingestion point for audio the way video has RTCCVPixelBuffer.
// The supported mechanism is implementing RTCAudioDevice and delivering PCM
// through the delegate's deliverRecordedData block, bypassing the default
// AVAudioSession-based ADM entirely — which we don't want anyway, since a
// Broadcast Extension can't freely drive AVAudioSession, and ReplayKit is
// already handing us sample buffers for both app and mic audio.
//
// Every member here is verified against the actual RTCAudioDevice.h /
// RTCAudioDeviceDelegate protocol shipped in StreamWebRTC 148.0.0 (read
// directly from the built framework header, not guessed).
final class CustomAudioDeviceModule: NSObject, RTCAudioDevice {

    private weak var audioDelegate: RTCAudioDeviceDelegate?

    // MARK: - Reported format
    // WebRTC's ADM expects a fixed format and does not resample for you — mixed
    // app+mic PCM handed to deliverCapturedPCM must already be in this format.
    let deviceInputSampleRate: Double = 48_000
    let inputIOBufferDuration: TimeInterval = 0.02
    let inputNumberOfChannels: Int = 2
    let inputLatency: TimeInterval = 0.02

    // No real playout device in the extension (no speaker output), but the
    // protocol still requires these to be reported — mirror the input format.
    let deviceOutputSampleRate: Double = 48_000
    let outputIOBufferDuration: TimeInterval = 0.02
    let outputNumberOfChannels: Int = 2
    let outputLatency: TimeInterval = 0.02

    // MARK: - State

    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    // Running sample-clock position for AudioTimeStamp.mSampleTime — a monotonic
    // count of frames delivered so far, not wall-clock time.
    private var recordedSampleTime: Float64 = 0

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

    func initializePlayout() -> Bool {
        isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        // No local playout in the extension — nothing to actually start, but we
        // must still report success/state truthfully per the protocol contract.
        isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        isPlaying = false
        return true
    }

    func initializeRecording() -> Bool {
        isRecordingInitialized = true
        return true
    }

    func startRecording() -> Bool {
        isRecording = true
        return true
    }

    func stopRecording() -> Bool {
        isRecording = false
        return true
    }

    // MARK: - Feeding audio in

    /// Call from SampleHandler.processSampleBuffer for both .audioApp and .audioMic
    /// sample types, after mixing them into one PCM stream at deviceInputSampleRate/
    /// inputNumberOfChannels (resample upstream if ReplayKit hands you a different format).
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

        let frameCount = UInt32(CMSampleBufferGetNumSamples(sampleBuffer))

        var actionFlags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = recordedSampleTime
        timeStamp.mFlags = .sampleTimeValid
        recordedSampleTime += Float64(frameCount)

        withUnsafePointer(to: audioBufferList) { inputDataPtr in
            _ = audioDelegate.deliverRecordedData(
                &actionFlags,
                &timeStamp,
                1, // inputBusNumber — 1 is the conventional Remote I/O input bus.
                frameCount,
                inputDataPtr,
                nil, // renderContext — unused in the "push" (pre-filled inputData) path.
                nil  // renderBlock — nil because we're pushing inputData directly,
                     // not pulling via a render callback (see deliverRecordedData's
                     // doc comment in RTCAudioDevice.h: either inputData or
                     // renderBlock must be provided; we provide inputData).
            )
        }
    }
}
