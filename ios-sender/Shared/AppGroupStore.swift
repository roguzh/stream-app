import Foundation

enum AppGroupStore {
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
    }

    private static var pairingFileURL: URL? {
        containerURL?.appendingPathComponent(AppConstants.pairingFileName)
    }

    static func writePairingSession(_ session: PairingSession) {
        guard let url = pairingFileURL else { return }
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("AppGroupStore: failed to write pairing session: \(error)")
        }
    }

    static func readPairingSession() -> PairingSession? {
        guard let url = pairingFileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PairingSession.self, from: data)
    }

    static func clearPairingSession() {
        guard let url = pairingFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // Temporary diagnostic aid: NSLog output from the extension process can't be
    // retrieved remotely (no live log-streaming path available), but files in the
    // App Group container can be pulled via `devicectl device info files
    // --domain-type appGroupDataContainer`. Appends a timestamped line; callers
    // should throttle (don't call this per-frame at 30-60fps).
    private static var diagnosticFileURL: URL? {
        containerURL?.appendingPathComponent("diagnostic.log")
    }

    // Primary diagnostic channel: devicectl's remote file-transfer commands proved
    // unreliable for reading files back out of the App Group container (consistent
    // "File paths cannot contain '..'" errors unrelated to the actual path given,
    // even for pairing.json which we know for certain gets written successfully).
    // POSTing straight to the dev Mac's already-running, already-trusted server is
    // far more reliable — its console output is just directly tailable.
    // TEMPORARY — remove once the zero-frames issue is diagnosed.
    private static let debugLogURL = URL(string: "http://192.168.1.9:3000/debug-log")

    static func logDiagnostic(_ message: String) {
        // File-based logging kept as a secondary path even though retrieval via
        // devicectl proved unreliable — harmless to keep writing it.
        if let url = diagnosticFileURL {
            let line = "\(Date()): \(message)\n"
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                } else {
                    try? data.write(to: url)
                }
            }
        }

        if let debugLogURL {
            var request = URLRequest(url: debugLogURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "message": message,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    static func clearDiagnosticLog() {
        guard let url = diagnosticFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// Darwin notifications are the only reliable cross-process signal between the main
// app and the Broadcast Extension (separate processes — App Group UserDefaults
// changes aren't directly observable, no shared-memory KVO). They carry no payload;
// the actual data always goes through AppGroupStore's JSON file.
//
// IMPORTANT: a notification posted before the observer registers is silently
// dropped — there is no queuing. Pair this with a short polling fallback on the
// observing side rather than relying on the notification alone.
enum DarwinNotifications {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    // `handler` is invoked on an arbitrary thread — hop to main yourself if needed.
    static func observe(_ name: String, handler: @escaping () -> Void) -> DarwinObserverToken {
        let token = DarwinObserverToken(name: name, handler: handler)
        let observer = Unmanaged.passUnretained(token).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observerPtr, _, _, _ in
                guard let observerPtr = observerPtr else { return }
                let token = Unmanaged<DarwinObserverToken>.fromOpaque(observerPtr).takeUnretainedValue()
                token.handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
        return token
    }

    static func stopObserving(_ token: DarwinObserverToken) {
        let observer = Unmanaged.passUnretained(token).toOpaque()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            CFNotificationName(token.name as CFString),
            nil
        )
    }
}

// Keeps the observer + closure alive for as long as the caller holds a reference;
// pass the same instance to stopObserving() when done (e.g. in deinit).
final class DarwinObserverToken {
    let name: String
    let handler: () -> Void
    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
    }
}
