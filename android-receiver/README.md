# stream-app — Android TV receiver

A native Android TV client for the Mi Box that replaces opening `receiver.html` in a browser. It talks to the exact same `server.js` signaling server — no server-side changes needed, so the Mac/iPhone sender pages work unchanged.

What's better than the browser receiver:
- Hardware-accelerated H.264 decode via `DefaultVideoDecoderFactory` (the browser receiver depends on whatever the Mi Box's browser app does, which varies)
- No autoplay-mute dance — native audio playback just works, no "tap for sound" button needed
- No "tap to go fullscreen" step — the app is immersive fullscreen from launch
- A real launcher banner/icon so it shows up in the Android TV home screen

This is a genuinely different toolchain from the rest of the project (Kotlin/Gradle/Android Studio instead of Node/HTML), and **I wasn't able to compile or run this myself** — there's no Android SDK, emulator, or physical Mi Box available in the environment this was written in. The WebRTC/Socket.io API calls are written against the current stable library versions as of writing, but if Android Studio's first Gradle sync flags a small API mismatch, that's expected — it'll be a quick fix guided by the inline error, not a sign the whole approach is wrong.

## 1. Install Android Studio

Download from [developer.android.com/studio](https://developer.android.com/studio) and run the installer — it bundles its own JDK and Android SDK, so there's nothing else to install separately.

## 2. Open the project

`File → Open` and select the `android-receiver/` folder (not the whole `stream-app` repo — this subfolder is its own Gradle project). Android Studio will detect it's missing a Gradle wrapper JAR and offer to generate one automatically; accept that. First sync can take a few minutes while it downloads the Android SDK platform, build tools, and the dependencies (`stream-webrtc-android`, `socket.io-client`).

If Gradle sync reports a version conflict or missing API, it's almost always Android Studio offering to auto-upgrade something (an AGP/Gradle version bump) — accept those suggestions.

## 3. Enable sideloading on the Mi Box

1. On the Mi Box: **Settings → Device Preferences → About** → click **Build** 7 times to unlock Developer options
2. Back out to **Settings → Device Preferences → Developer options** → enable **USB debugging** and **Network debugging** (naming varies slightly by Android TV version — look for anything mentioning ADB)
3. Find the Mi Box's IP address: **Settings → Network & Internet** (or it's printed on screen when Network debugging is enabled)

## 4. Connect and install

From a terminal, with the Mi Box and your Mac on the same LAN:

```bash
adb connect <mibox-ip>:5555
```

Then either:
- **From Android Studio**: the Mi Box should now appear in the device dropdown next to the Run button — select it and click Run. This builds, installs, and launches the app in one step.
- **From the command line**:
  ```bash
  cd android-receiver
  ./gradlew installDebug
  ```

If `adb connect` doesn't work (some Mi Box firmware only exposes ADB over USB, not network), an alternative is to sideload without ADB at all: build the APK (`./gradlew assembleDebug`, output lands in `app/build/outputs/apk/debug/app-debug.apk`), serve that file from your Mac (`python3 -m http.server` in that directory), install the **Downloader** app from the Mi Box's app store, and point it at `http://<mac-ip>:8000/app-debug.apk` to download and install directly on the box.

## 5. First launch

The app asks for the signaling server's address — enter the same `host:port` that `npm start` prints as the `Network:` URL in the main project (e.g. `192.168.1.19:3000`), no `http://` needed. It's saved on-device, so this is a one-time step; a "Change server" button is available later if your Mac's IP changes.

Once connected, it behaves like the browser receiver: waits for a stream, goes fullscreen automatically when one arrives, and shows a stats overlay (resolution, decoded fps, dropped frames/sec, codec) on any remote key press.

## Rebuilding after code changes

```bash
./gradlew installDebug
```

reinstalls over the existing app on whatever device `adb` is currently connected to.
