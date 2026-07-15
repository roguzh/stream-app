# stream-app

A self-hosted, LAN-only screen-streaming app. Stream your Mac or iPhone's screen to a TV browser (e.g. a Xiaomi Mi Box) at up to 1080p60 over WebRTC — no cloud services, no accounts, no internet dependency.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## About

Screen-mirroring solutions usually mean AirPlay licensing headaches, Chromecast quirks, or third-party apps phoning home. This is the opposite: a small Node server on your LAN that does nothing but introduce two browsers to each other. Once they're connected, video flows directly peer-to-peer over WebRTC — the server never touches the video stream itself.

Point any browser's screen-share at another browser's `<video>` tag, in H.264, at a real bitrate. That's the whole app.

## Features

- Peer-to-peer WebRTC video — server only relays signaling, never touches media
- H.264 forced via `setCodecPreferences()` (highest available profile) with SDP munging as fallback
- Tuned for sustained 60fps under motion: `contentHint`, `degradationPreference`, and a bitrate ceiling per quality preset — see [Quality tuning](#quality-tuning)
- Selectable resolution presets (1080p60/1440p60/4K30) with automatic fallback when the encoder or the TV's decoder falls behind — see [Automatic quality fallback](#automatic-quality-fallback)
- Optional password protection on the signaling channel — see [Password protection](#password-protection)
- Fullscreen receiver UI with a live stats overlay (resolution, fps, dropped frames, bitrate, codec, connection state)
- QR code on the sender page for quick access to the receiver URL
- Auto-reconnect on the receiver if the sender drops
- Works from iPhone Safari (tab-share) as well as Mac Chrome (full screen)
- Zero build step — plain HTML/JS/CSS, no bundler, no framework, no TypeScript

## Requirements

- Node.js 18+
- All devices on the same LAN (no STUN/TURN — this intentionally will not work across networks)
- A Chromium-based browser (Chrome/Edge) for the sender for full screen-share support; Safari on iPhone supports tab-share only
- Any modern browser on the receiving device (Chrome or Firefox both work fine on Android TV-based devices like the Mi Box)

## Installation

```bash
git clone https://github.com/roguzh/stream-app.git
cd stream-app
npm install
```

## Usage

```bash
npm start
```

The server prints the URLs to use:

```
Stream app running:
  Local:   http://localhost:3000
  Network: http://192.168.1.19:3000

Open /sender on Mac/iPhone
Open /receiver on Mi Box
```

1. On the Mac or iPhone, open `http://<network-ip>:3000/sender` in Chrome (or Safari on iPhone).
2. On the Mi Box (or any other LAN device), open `http://<network-ip>:3000/receiver` in its browser. Scanning the QR code on the sender page is the fastest way to do this.
3. On the sender, click **Start Streaming** and choose what to share.
4. The receiver picks up the stream automatically and goes fullscreen.

Stop streaming from the sender's **Stop** button, or by using the browser's native "Stop sharing" control — either way the receiver detects the drop and shows a reconnect screen.

### Streaming system audio (Mac)

Chrome on macOS only offers a "share audio" checkbox when you share a **Chrome tab** — sharing the entire screen or a window never includes app audio (a QuickTime video, Spotify, a native app, another browser) due to a macOS/Chrome platform limitation, not anything this app controls.

If you're sharing a Chrome tab, you're done — check "Share tab audio" in the picker and it flows through automatically.

If you're sharing the entire screen or a window and want that audio too, you need a virtual audio driver to route system output back in as a capturable input:

1. **Install [BlackHole](https://github.com/ExistentialAudio/BlackHole)** (free, open source):
   ```bash
   brew install blackhole-2ch
   ```
   macOS will ask you to approve the new audio driver in **System Settings → Privacy & Security** — you'll need to do that step yourself and may be prompted to restart the Core Audio service or log out/in.

2. **Create a Multi-Output Device** so you still hear audio locally instead of it going silently into BlackHole:
   - Open **Audio MIDI Setup** (Spotlight → "Audio MIDI Setup")
   - Click **+** → **Create Multi-Output Device**
   - Check both your normal speakers/headphones **and** "BlackHole 2ch"
   - Set this Multi-Output Device as your Mac's audio output (**System Settings → Sound**, or the menu bar volume icon)

3. On the sender page, the **System audio source** dropdown will list "BlackHole 2ch" once the browser has microphone permission (Chrome will prompt on first use). Select it before clicking **Start Streaming**.

The sender page auto-detects a device with "blackhole" in its name and pre-selects it. This also works with similar tools (Loopback, Soundflower) — anything that appears as an audio input device.

### Configuration

```bash
PORT=8080 STREAM_PASSWORD=hunter2 npm start
```

- `PORT` — defaults to `3000` if unset.
- `STREAM_PASSWORD` — optional, see [Password protection](#password-protection) below. Unset by default (open access).

### Password protection

Set `STREAM_PASSWORD` when starting the server to require a password before any sender or receiver can join the signaling channel:

```bash
STREAM_PASSWORD=hunter2 npm start
```

The static pages (`/sender`, `/receiver`) still load without a password — the app's source is public on GitHub either way, so there's nothing sensitive in the HTML/JS itself. What's actually gated is the WebRTC signaling handshake, i.e. who can join the room and see or inject the stream. When a password is required, the browser sender/receiver pages show a password prompt and remember it in `localStorage` for next time; the native Android app has a password field on its server-entry screen, saved alongside the server address.

Leave `STREAM_PASSWORD` unset for open access (the default) — reasonable for a typical home LAN.

### Automatic quality fallback

The sender's **Auto-adjust quality** checkbox (on by default) watches two independent signals every second and steps the stream down through a ladder of lower resolution/bitrate/framerate combinations when either one is struggling:

- **Encoder-side**: the sender's own `qualityLimitationReason` stat (`cpu` or `bandwidth`) — the Mac itself can't keep up.
- **Decoder-side**: dropped-frames-per-second reported back by the receiver over the signaling channel — the TV can't keep up, which the sender has no way to see on its own otherwise.

It's quick to step down (3 consecutive bad readings, ~3 seconds) and slow to step back up (15 consecutive clean readings, ~15 seconds) to avoid visibly oscillating between quality levels. Steps only ever go as high as whatever preset you selected in the **Stream quality** dropdown — auto-adjust narrows down from there, it never exceeds your chosen ceiling. When it's kicked in, the sender's stats overlay shows `auto: reduced (L1)` or `(L2)` next to the limitation reason. Uncheck the box to pin to your manually selected preset instead.

## How it works

```
 Sender (Mac/iPhone)                Server (Node)                Receiver (Mi Box)
 ┌──────────────────┐          ┌───────────────────┐          ┌──────────────────┐
 │ getDisplayMedia() │          │  Express (static)  │          │   <video> tag     │
 │ RTCPeerConnection │◄────────►│  Socket.io (relay)  │◄────────►│ RTCPeerConnection │
 └──────────────────┘  signal   └───────────────────┘  signal   └──────────────────┘
          │                                                              ▲
          └──────────────────── WebRTC media (P2P, H.264) ───────────────┘
```

- `server.js` is a thin Express + Socket.io relay. It serves the two static pages and forwards SDP offers/answers and ICE candidates between whoever is in the `"stream"` room. It never sees the video itself.
- `public/sender.html` captures the screen with `getDisplayMedia()`, forces H.264 (highest available profile) via `setCodecPreferences()` with SDP munging as a fallback, and applies `RTCRtpSender.setParameters()` to push bitrate up to a 20 Mbps ceiling (WebRTC defaults to ~1 Mbps/30fps otherwise).
- `public/receiver.html` waits for an offer, answers it, and renders the incoming track fullscreen with a toggleable stats overlay.

Since there's no STUN/TURN server, both peers connect with an empty ICE server list — this only works when sender and receiver are reachable from each other directly, i.e. same LAN.

### Quality tuning

Getting a consistent 60fps out of WebRTC screen-share takes more than just requesting it — several defaults work against you, especially with high-motion content like video/movie playback:

- **`contentHint = 'motion'`** on the captured track. Browsers default to biasing the encoder toward spatial sharpness (good for reading static UI text, bad for moving video) — this flips that priority toward temporal smoothness.
- **`degradationPreference: 'maintain-framerate'`** on the sender's encoding params. If the encoder ever has to shed load, it drops resolution before framerate, instead of the default "balanced" behavior which can do either.
- **20 Mbps bitrate ceiling.** LAN has bandwidth to spare, so the encoder is never starved of bits for complex/high-entropy content (movies have far more motion and detail than a static desktop).
- **H.264 profile preference.** `setCodecPreferences()` sorts available H.264 profiles High > Main > Baseline before falling back to other codecs — higher profiles compress more efficiently at the same bitrate.
- **Quality params applied immediately** after the offer is created rather than waiting for `connectionState === 'connected'`, cutting out several seconds of default-bitrate ramp-up on every stream start.
- **Receiver-side jitter buffer** (`playoutDelayHint`) is nudged up slightly to absorb network jitter without dropping frames, trading a small amount of latency that doesn't matter for screen mirroring.

Both stats overlays now surface the diagnostics that matter for chasing quality issues:
- **Sender**: codec in use, and `qualityLimitationReason` (`cpu`, `bandwidth`, or `none`) — tells you definitively whether the Mac's encoder is the bottleneck.
- **Receiver**: dropped frames per second — if this climbs during movie playback, the TV's decoder (not the network or the sender) can't keep up, which is common on lower-power Android TV boxes doing software decode of complex content.

### Resolution presets

The sender has a **Stream quality** dropdown with three presets, each scaling both the capture constraints and the bitrate ceiling together:

| Preset | Resolution | Framerate | Bitrate ceiling |
|---|---|---|---|
| 1080p60 (default) | 1920×1080 | 60fps | 20 Mbps |
| 1440p60 | 2560×1440 | 60fps | 30 Mbps |
| 4K30 | 3840×2160 | 30fps (60fps at 4K is unrealistic for real-time software/most hardware encoders) | 40 Mbps |

Higher presets need more from *both* ends — the Mac's encoder and the TV's decoder. If the receiver's dropped-frames stat climbs after switching up a preset, that's the TV's decoder falling behind, not a sender or network problem; step back down.

### Audio quality and "staggering"

If audio sounds like it's stuttering or dropping out momentarily, two things were actually wrong, both now fixed:

1. **Audio was never given the same sender priority as video.** `RTCRtpEncodingParameters.priority` defaults to `'low'` — video was explicitly boosted to `'high'`, but audio was left at the default. Under any network congestion, WebRTC's bandwidth allocation favors the higher-priority stream, so audio was the first thing sacrificed. Audio is now set to `'high'` priority too, with a 128 kbps ceiling — plenty for stereo system audio.
2. **Opus was running with voice-call defaults.** DTX (discontinuous transmission, which aggressively stops sending audio during "silence") creates audible gaps in music/movie audio that isn't actually silent, and without in-band FEC a single lost Wi-Fi packet drops a chunk of audio outright instead of being reconstructed. The offer SDP now explicitly sets `usedtx=0` and `useinbandfec=1` on the Opus payload (along with `stereo=1` to prevent downmixing).

## Project structure

```
stream-app/
├── package.json
├── server.js               # Express + Socket.io signaling server
├── public/
│   ├── sender.html          # Opened on Mac or iPhone
│   ├── receiver.html        # Opened on the TV browser (or use a native app below);
│   │                        # also supports serverless pairing mode — see below
│   └── auth.js              # Shared password-prompt helper
├── android-receiver/        # Native Android TV client — see android-receiver/README.md
└── ios-sender/               # Native iOS "phone hosts itself" sender — see ios-sender/README.md
```

## Native Android TV receiver

Instead of opening `receiver.html` in whatever browser the Mi Box has, there's a native Android TV app in [`android-receiver/`](android-receiver/) that talks to the same signaling server unchanged. It gets hardware-accelerated decode, real fullscreen without a tap-to-fullscreen step, and audio that just plays without the browser autoplay-mute workaround. It's a separate Kotlin/Android Studio project — see [android-receiver/README.md](android-receiver/README.md) for building and sideloading it onto the Mi Box.

## Native iOS sender (serverless — the phone hosts itself)

Every sender/receiver above connects through `server.js`, which has to run persistently on some machine. [`ios-sender/`](ios-sender/) is a different model: a native iOS app that captures the whole device screen and **hosts itself directly** — no central server at all, not even a persistent one on the phone (mobile OS background restrictions make long-lived embedded servers fragile). It does a brief one-shot local-network handoff instead:

1. The app shows a QR code (and the same info as plain text, for camera-less pairing).
2. A receiver — right now, `receiver.html`'s **Pair with sender** button — scans or enters it, fetches the offer directly from the phone (`GET /offer`), and posts back an answer (`POST /answer`).
3. WebRTC media then flows directly phone-to-receiver, same as every other connection in this project.

This uses **non-trickle ICE**: both sides wait for full local candidate gathering before exchanging SDP, so the whole handshake collapses to one request/response pair instead of needing an ongoing signaling channel. It's fully additive — `server.js` and the existing Socket.io-relay flow are completely untouched; pairing mode is a second, independent way to connect that happens to live in the same `receiver.html` file.

**This is genuinely unverified code** — it requires Xcode/a physical iPhone/an Apple ID to build and test, none of which were available while writing it. The wire protocol (the fetch/POST exchange above) *is* verified, tested against a mock server standing in for the phone. Everything inside the Xcode project itself is not. See [ios-sender/README.md](ios-sender/README.md) for the full picture, including which specific files are the highest-risk (`CustomAudioDeviceModule.swift` especially) and where to start debugging if the first build doesn't work.

Android-as-sender (the same self-hosting model, for Android phones) is a planned follow-up, not built yet.

## Known limitations

- **LAN only, by design.** No STUN/TURN servers are configured, so this will not work across different networks (e.g. streaming to a TV that isn't on the same Wi-Fi/router).
- **No authentication by default.** Anyone on the LAN can join the stream unless you set `STREAM_PASSWORD` — see [Password protection](#password-protection). Even with a password, the static pages themselves still load for anyone (harmless, since the source is public anyway); only joining the actual WebRTC session is gated.
- **Single sender, single receiver.** The signaling relay uses one hardcoded room (`"stream"`). A second sender or receiver joining now gets a clear rejection message instead of silently cross-talking with the existing session, but there's still no support for genuinely running more than one of each at a time.
- **No HTTPS.** `getDisplayMedia()` works over plain HTTP for `localhost` and LAN IPs in Chrome, so this is intentional — don't try to expose this server outside your LAN.
- **iPhone Safari can only share a browser tab**, not the full device screen, and doesn't capture system audio at all — no workaround exists for the browser path. The native [ios-sender/](ios-sender/) app captures the full screen instead, but is unverified — see its README.
- **Chrome on Mac only captures audio natively when sharing a tab.** Full-screen and window capture never include app audio (macOS/Chrome platform limitation) — see [Streaming system audio (Mac)](#streaming-system-audio-mac) for the BlackHole-based workaround.
- **IP autodetection** picks the first real (non-bridge, non-VPN) IPv4 interface it finds. If your Mac has multiple active network interfaces, double check the printed `Network:` URL is actually reachable from your TV before assuming it's wrong.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Receiver stuck on "Waiting for stream…" | Sender hasn't clicked Start Streaming yet, or they're not both on the same LAN |
| "Cannot reach server" on either page | Server isn't running, or a firewall is blocking the port |
| Low bitrate / blurry video | Wi-Fi congestion — try wired Ethernet on the sender, or move closer to the AP |
| No H.264 in codec list | Browser/OS doesn't support it in this context; the app falls back to whatever codec is offered (VP8/VP9) |
| Stream drops repeatedly | Check Wi-Fi signal strength on both ends; the receiver auto-reloads 3s after a dropped connection |
| Video works but no sound, even with tab/system audio set up correctly | Browser autoplay policy blocks unmuted `autoplay` — the receiver starts muted so video always plays automatically, then tries to unmute itself. If the browser blocks that too, a "🔇 Tap for sound" button appears bottom-left; click it (or press OK on the TV remote) to unmute |
| "Pair with sender" fails with a connection error | The pairing URL is wrong/stale (each broadcast session gets a fresh one — rescan/re-enter it), the two devices aren't on the same LAN, or the iOS app's listener isn't actually running (unverified code — check Xcode's console output on the phone) |

## Contributing

This is a small personal-use project, but pull requests are welcome — bug fixes, additional browser compatibility, or UI polish. Please keep the zero-build-step, zero-framework philosophy: no bundler, no TypeScript, no new runtime dependencies without a good reason.

## License

MIT — see [LICENSE](LICENSE).
