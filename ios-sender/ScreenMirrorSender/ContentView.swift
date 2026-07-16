import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PairingViewModel()

    var body: some View {
        VStack(spacing: 24) {
            Text("Stream to TV")
                .font(.largeTitle.bold())

            switch viewModel.state {
            case .idle, .waitingForBroadcastStart, .waitingForOffer:
                pickerView
            case .ready(let session):
                readyView(session: session)
            case .receiverConnected:
                connectedView
            case .timedOut:
                errorView(message: "No broadcast started — tap the button below, then choose \"ScreenMirrorSender\" from the picker and tap Start Broadcast.")
            case .stopped:
                stoppedView
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        // Arm listeners as soon as the screen appears, not tied to the picker
        // button itself — see pickerView's doc comment for why.
        .onAppear { viewModel.startWaiting() }
    }

    // RPSystemBroadcastPickerView gives no tap or completion callback (Apple
    // doesn't expose one), so this view must stay mounted and tappable for the
    // entire time the user might interact with it — including the real gap
    // between tapping it, picking "ScreenMirrorSender" in the system sheet, and
    // tapping "Start Broadcast" there, which can take several seconds.
    //
    // An earlier version hid this button behind a waiting-state view swap
    // triggered by the button's own onAppear — which fires the instant the view
    // *renders*, not when it's *tapped* — so the button vanished before the user
    // ever got a chance to tap it, showing only a permanent "waiting" spinner.
    private var pickerView: some View {
        VStack(spacing: 16) {
            Text("Tap below, then choose \"ScreenMirrorSender\" from the system picker to start mirroring your screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            BroadcastPickerView()
                .frame(width: 60, height: 60)

            if case .waitingForBroadcastStart = viewModel.state {
                ProgressView()
                    .tint(.white)
                Text("Waiting for broadcast to start…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readyView(session: PairingSession) -> some View {
        VStack(spacing: 16) {
            Text("Scan this on the receiver")
                .font(.headline)

            QRCodeView(content: session.pairingURLString)
                .frame(width: 240, height: 240)
                .padding(12)
                .background(Color.white)
                .cornerRadius(12)

            Text(session.pairingURLString)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // ReplayKit broadcasts can only actually be stopped via the system's red
            // recording indicator or Control Center — this app has no programmatic
            // control over the extension's lifecycle. This button only resets the
            // app's own pairing UI state, it doesn't end the broadcast itself.
            Text("To stop mirroring, tap the red status bar indicator or use Control Center.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Dismiss") {
                viewModel.reset()
            }
            .buttonStyle(.bordered)
        }
    }

    private var connectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Receiver connected")
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again") { viewModel.reset() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var stoppedView: some View {
        VStack(spacing: 16) {
            Text("Broadcast stopped")
            Button("Start Again") { viewModel.reset() }
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
}
