# stream-app — iOS sender (serverless, phone-as-host)

Unlike the rest of this project, this app doesn't connect to `server.js` at all. It's a native iOS app that captures your iPhone's full screen and hosts itself directly on your LAN — no central signaling server required. Start mirroring, scan the QR code it shows on a receiver (currently `public/receiver.html`, via its **Pair with sender** button), and video/audio flow peer-to-peer.

**Compiles clean, but has never run.** This was originally written with zero access to Xcode, and several `RTCAudioDevice`/`RTCRtpTransceiver`/`RTCPeerConnectionFactory` API calls turned out to be wrong on the first real build — wrong method names, wrong types passed to `sorted`, an `isScreencast` property that doesn't exist in this SDK version, and a `setCodecPreferences` overload with a genuinely strange bridged signature. All of that has since been fixed and verified against the actual StreamWebRTC 148.0.0 headers (`xcodebuild ... CODE_SIGNING_ALLOWED=NO` succeeds with zero errors and zero warnings) — see the fix commit for the exact diffs and the reasoning behind each one. What's still unverified is runtime behavior: actual screen capture, actual PCM delivery through `CustomAudioDeviceModule`, actual negotiation with a real receiver. Treat running it on a device as the next real test, not a formality — a clean compile rules out typos and wrong signatures, not wrong runtime assumptions.

## What's verified vs. not

| Piece | Status |
|---|---|
| Wire protocol (`GET /offer`, `POST /answer`, CORS) | **Verified** — tested end-to-end against a real browser `RTCPeerConnection` using a mock Node server standing in for the iOS listener. `public/receiver.html`'s pairing-mode code is confirmed correct. |
| Everything inside `ScreenMirrorBroadcastExtension/` and `ScreenMirrorSender/` compiles | **Verified** — `xcodebuild` succeeds with zero errors/warnings against the real StreamWebRTC 148.0.0 API. |
| Actual runtime behavior (screen capture, audio delivery, real negotiation) | **Not verified.** No run on a physical device yet — that's the next test. |

## 1. Install prerequisites

```bash
brew install xcodegen
```

Also install Xcode from the App Store if you haven't (this project targets iOS 15+; use a reasonably current Xcode).

## 2. Generate the Xcode project

This repo intentionally does **not** commit a `.xcodeproj` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates it from `project.yml` so the project definition stays readable/diffable in git instead of a giant generated pbxproj file.

```bash
cd ios-sender
xcodegen generate
open ScreenMirrorSender.xcodeproj
```

## 3. Configure signing

Xcode needs a real Apple ID to sign and install on a device (a free personal-team Apple ID works fine for this — App Groups and Broadcast Extensions are both available to free accounts, though apps signed this way need reinstalling every 7 days; a paid $99/year Developer account avoids that).

For **both** targets (`ScreenMirrorSender` and `ScreenMirrorBroadcastExtension`):
1. Select the target → **Signing & Capabilities**
2. Set **Team** to your Apple ID
3. Signing is already set to Automatic in `project.yml` — Xcode should resolve a provisioning profile itself
4. If you changed `bundleIdPrefix` in `project.yml` away from `com.streamapp`, also update `AppConstants.broadcastExtensionBundleID` in `Shared/Constants.swift` to match — nothing derives it automatically, and `RPSystemBroadcastPickerView` needs the exact extension bundle ID to find it.

The App Group (`group.com.streamapp.screenmirror`) should register itself automatically the first time you build, as part of automatic signing. If Xcode complains about it, add it manually under **Signing & Capabilities → + Capability → App Groups** on both targets.

## 4. Run on a physical device

**Screen capture requires a real device — the iOS Simulator cannot meaningfully test ReplayKit broadcast capture.** Connect your iPhone, select it as the run destination, and hit Run. First launch will prompt for local network permission (needed to advertise/listen for a receiver) — allow it.

## 5. Using it

1. Open the app, tap the round broadcast button, choose **ScreenMirrorSender** from the system picker, tap **Start Broadcast**.
2. A QR code appears (also shown as plain text below it, for camera-less pairing).
3. On the receiver — right now, `public/receiver.html` opened in any browser on the same LAN — tap **Pair with sender** (top-left), then either scan the QR or paste/type the URL, then **Connect**.
4. Video should start flowing directly between the two devices. To stop, use the red recording indicator in the status bar or Control Center (ReplayKit broadcasts can only be stopped via the system UI, not from within this app).

## If something breaks in Xcode

The build itself is verified clean (`xcodebuild ... CODE_SIGNING_ALLOWED=NO`, zero errors/warnings against StreamWebRTC 148.0.0). If your build still fails, it's most likely one of:
- **Signing** — "requires a development team" means the Team dropdown under Signing & Capabilities isn't set on one or both targets (`ScreenMirrorSender` and `ScreenMirrorBroadcastExtension` need it set independently).
- **Running the wrong scheme** — if Run shows a "choose an app to run" dialog with unrelated options (Siri, Today, etc.), the extension's own launch action got selected instead of the app's. The `ScreenMirrorSender` scheme should always be what's selected in the toolbar.
- **A StreamWebRTC version drift** — if a future dependency bump changes an API shape again, the fix pattern that worked here was: read the actual header in `~/Library/Developer/Xcode/DerivedData/.../StreamWebRTC.xcframework/.../Headers/` directly (`RTCAudioDevice.h`, `RTCRtpTransceiver.h`, `RTCPeerConnectionFactory.h`, `RTCRtpCodecCapability.h` are the ones this code depends on most), not the docs — this SDK's Swift bridging has real surprises (e.g. `setCodecPreferences` has a bridged signature that looks like a compiler bug but isn't).

Priority order once it's running on a device, per the original risk list:
1. **Audio (`CustomAudioDeviceModule.swift`)** — get this working in isolation first, independent of the rest of the pipeline. Confirm a receiver can hear anything before worrying about video.
2. **Broadcast Extension memory** — if the extension crashes/gets killed shortly after starting, this is almost certainly it (~50MB budget, undocumented and shifting across iOS versions). Profile with Instruments on your device.
3. Everything else in the risk list is in `ScreenMirrorBroadcastExtension/*.swift`'s file-header comments.

## What's explicitly out of scope here

- **Android-as-sender-host app** — planned as a separate future phase, not part of this.
- **Quality preset selection / audio device picker** — the sender.html equivalents (1080p/1440p/4K presets, BlackHole-style audio source selection, auto quality fallback) don't exist here yet. This app currently just captures at whatever ReplayKit hands it, encoded at a fixed 20 Mbps/30fps ceiling (see `AppConstants.swift`).
- **Pairing-mode support in the Android TV native receiver** — only `receiver.html` supports the new pairing protocol so far.
