# stream-app — iOS sender (serverless, phone-as-host)

Unlike the rest of this project, this app doesn't connect to `server.js` at all. It's a native iOS app that captures your iPhone's full screen and hosts itself directly on your LAN — no central signaling server required. Start mirroring, scan the QR code it shows on a receiver (currently `public/receiver.html`, via its **Pair with sender** button), and video/audio flow peer-to-peer.

**This is the least-tested code in the whole project.** I wrote it with zero access to Xcode, an iOS simulator, an Apple Developer account, or a physical iPhone — none of it has compiled, let alone run. Several files contain `// VERIFY:` comments marking API calls whose exact names/signatures I'm not fully certain of (this corner of the WebRTC iOS SDK is genuinely under-documented). Treat your first Xcode build as the actual first test of this code, not a formality. See [`~/.claude/plans/moonlit-churning-mccarthy.md`](../.claude/plans/moonlit-churning-mccarthy.md) *(if still present on your machine)* for the full architecture writeup and risk list this was built from.

## What's verified vs. not

| Piece | Status |
|---|---|
| Wire protocol (`GET /offer`, `POST /answer`, CORS) | **Verified** — tested end-to-end against a real browser `RTCPeerConnection` using a mock Node server standing in for the iOS listener. `public/receiver.html`'s pairing-mode code is confirmed correct. |
| Everything inside `ScreenMirrorBroadcastExtension/` and `ScreenMirrorSender/` (Swift/Xcode/ReplayKit/WebRTC) | **Not verified at all.** No compile, no run. |

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

Start with `CustomAudioDeviceModule.swift` and `WebRTCSessionManager.swift` — those have the most `// VERIFY:` comments and are the most likely places a StreamWebRTC API name doesn't match exactly what I wrote. Cmd-click into the type/protocol Xcode is complaining about and check the actual declaration; the fix is almost always a renamed method or a slightly different parameter list, not a wrong overall approach.

Priority order for debugging, per the plan's risk list:
1. **Audio (`CustomAudioDeviceModule.swift`)** — get this working in isolation first, independent of the rest of the pipeline. Confirm a receiver can hear anything before worrying about video.
2. **Broadcast Extension memory** — if the extension crashes/gets killed shortly after starting, this is almost certainly it (~50MB budget, undocumented and shifting across iOS versions). Profile with Instruments on your device.
3. Everything else in the risk list is in `ScreenMirrorBroadcastExtension/*.swift`'s file-header comments.

## What's explicitly out of scope here

- **Android-as-sender-host app** — planned as a separate future phase, not part of this.
- **Quality preset selection / audio device picker** — the sender.html equivalents (1080p/1440p/4K presets, BlackHole-style audio source selection, auto quality fallback) don't exist here yet. This app currently just captures at whatever ReplayKit hands it, encoded at a fixed 20 Mbps/30fps ceiling (see `AppConstants.swift`).
- **Pairing-mode support in the Android TV native receiver** — only `receiver.html` supports the new pairing protocol so far.
