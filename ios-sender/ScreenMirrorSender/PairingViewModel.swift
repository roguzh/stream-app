import Foundation

@MainActor
final class PairingViewModel: ObservableObject {
    @Published var state: PairingState = .idle

    // Must hold a strong reference to every DarwinObserverToken — the notification
    // center only keeps an unretained pointer, so a token with nothing else
    // referencing it gets deallocated immediately and its observer silently stops
    // firing (or dangles). See AppGroupStore.swift's DarwinNotifications doc comment.
    private var darwinTokens: [DarwinObserverToken] = []
    private var pollingTimer: Timer?
    private var pickerTapTimeoutTimer: Timer?

    func startWaiting() {
        state = .waitingForBroadcastStart
        AppGroupStore.clearPairingSession()

        darwinTokens = [
            DarwinNotifications.observe(AppConstants.DarwinNotification.offerReady) { [weak self] in
                Task { @MainActor in self?.handleOfferReady() }
            },
            DarwinNotifications.observe(AppConstants.DarwinNotification.pairingTimedOut) { [weak self] in
                Task { @MainActor in self?.state = .timedOut }
            },
            DarwinNotifications.observe(AppConstants.DarwinNotification.broadcastStopped) { [weak self] in
                Task { @MainActor in self?.state = .stopped }
            },
        ]

        // Belt-and-suspenders: a Darwin notification posted before the observer
        // registers is silently dropped (no queuing) — poll the shared file too.
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForSession() }
        }

        // RPSystemBroadcastPickerView gives no cancellation callback — if nothing
        // shows up in a reasonable window, assume the user backed out of the picker.
        pickerTapTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                if case .waitingForBroadcastStart = self?.state {
                    self?.reset()
                }
            }
        }
    }

    private func pollForSession() {
        guard case .waitingForBroadcastStart = state else { return }
        guard let session = AppGroupStore.readPairingSession(), session.port != 0 else { return }
        state = .ready(session)
        pickerTapTimeoutTimer?.invalidate()
    }

    private func handleOfferReady() {
        guard let session = AppGroupStore.readPairingSession() else { return }
        state = .ready(session)
        pickerTapTimeoutTimer?.invalidate()
    }

    // Called after a picker-interaction timeout, and from the "Dismiss"/"Try
    // Again"/"Start Again" buttons. Re-arms listeners immediately rather than
    // leaving the app idle-but-deaf — without this, the app would stop
    // listening for a real broadcast start after the very first timeout or
    // dismiss, even though the picker button remains visible and tappable.
    func reset() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        pickerTapTimeoutTimer?.invalidate()
        pickerTapTimeoutTimer = nil
        darwinTokens.forEach { DarwinNotifications.stopObserving($0) }
        darwinTokens = []
        AppGroupStore.clearPairingSession()
        startWaiting()
    }
}
