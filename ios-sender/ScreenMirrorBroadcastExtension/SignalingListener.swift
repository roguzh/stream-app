import Network
import Foundation

// One-shot local HTTP-ish listener: serves the SDP offer once, accepts the SDP
// answer once, then shuts down. Deliberately not a persistent server — mobile OS
// background restrictions make long-lived embedded servers fragile, and we only
// ever need exactly this one exchange per session. Hand-rolled HTTP parsing since
// only two fixed request shapes are needed — no HTTP library dependency.
//
// CORS: the primary receiver target (public/receiver.html) fetch()es this from a
// different origin (the Node server's host:port), so every response must carry
// Access-Control-Allow-Origin, and preflight OPTIONS requests (which browsers send
// automatically before a POST with a JSON Content-Type) must be answered.
final class SignalingListener {
    enum ListenerError: Error {
        case couldNotBind
    }

    private var listener: NWListener?
    private let session: PairingSession
    private let queue = DispatchQueue(label: "com.streamapp.iossender.signaling")
    private var timeoutWorkItem: DispatchWorkItem?

    var onAnswerReceived: ((SDPPayload) -> Void)?
    var onTimeout: (() -> Void)?
    var onReady: ((UInt16) -> Void)? // called once bound, with the actual port

    init(session: PairingSession) {
        self.session = session
    }

    func start() throws {
        // Fixed port (not .any) so the receiver can remember the sender's address
        // across sessions — only the short pairing code needs retyping each time.
        // Small residual risk of the port being briefly unavailable right after a
        // previous session closed (TIME_WAIT) — acceptable for personal LAN use;
        // not worth a fallback-to-random-port retry for this app's scope.
        let port = NWEndpoint.Port(rawValue: AppConstants.signalingPort) ?? .any
        guard let listener = try? NWListener(using: .tcp, on: port) else {
            throw ListenerError.couldNotBind
        }
        self.listener = listener

        listener.service = NWListener.Service(name: session.sessionId, type: AppConstants.bonjourServiceType)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    self.onReady?(port)
                }
                self.armTimeout()
            case .failed:
                self.stop()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        timeoutWorkItem?.cancel()
        listener?.cancel()
        listener = nil
    }

    private func armTimeout() {
        let work = DispatchWorkItem { [weak self] in
            self?.onTimeout?()
            self?.stop()
        }
        timeoutWorkItem = work
        // 60s proved too tight in practice for manual URL entry across devices
        // (switching to the Mac, copy/pasting a long URL) — confirmed via a real
        // "connection refused" once the listener had already torn itself down
        // mid-attempt. QR scanning is fast enough that this won't matter there;
        // this mainly protects the manual-entry fallback path.
        queue.asyncAfter(deadline: .now() + 180, execute: work)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }

            guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { connection.cancel(); return }
                self.receive(on: connection, buffered: buffer)
                return
            }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerEndRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                self.respond(connection, status: 400, body: nil)
                return
            }
            let headerLines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = headerLines.first else {
                self.respond(connection, status: 400, body: nil)
                return
            }
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                self.respond(connection, status: 400, body: nil)
                return
            }
            let method = parts[0]
            let path = parts[1]

            if method == "OPTIONS" {
                self.respond(connection, status: 200, body: nil)
                return
            }

            let bodyStart = headerEndRange.upperBound
            let bodySoFar = buffer.subdata(in: bodyStart..<buffer.endIndex)

            if method == "GET" && path.hasPrefix(AppConstants.signalingPathOffer) {
                self.handleOfferRequest(connection: connection, path: path)
            } else if method == "POST" && path.hasPrefix(AppConstants.signalingPathAnswer) {
                let contentLength = self.contentLength(from: headerLines)
                if bodySoFar.count < contentLength {
                    self.receive(on: connection, buffered: buffer)
                    return
                }
                self.handleAnswerRequest(connection: connection, path: path, body: bodySoFar)
            } else {
                self.respond(connection, status: 404, body: nil)
            }
        }
    }

    private func contentLength(from headerLines: [String]) -> Int {
        for line in headerLines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func queryParam(_ name: String, in path: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: queryStart)...]
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == name { return kv[1] }
        }
        return nil
    }

    private func handleOfferRequest(connection: NWConnection, path: String) {
        guard queryParam("sid", in: path) == session.sessionId else {
            respond(connection, status: 403, body: nil)
            return
        }
        let payload = SDPPayload(type: "offer", sdp: session.offerSdp)
        guard let body = try? JSONEncoder().encode(payload) else {
            respond(connection, status: 500, body: nil)
            return
        }
        respond(connection, status: 200, body: body)
    }

    private func handleAnswerRequest(connection: NWConnection, path: String, body: Data) {
        guard queryParam("sid", in: path) == session.sessionId else {
            respond(connection, status: 403, body: nil)
            return
        }
        guard let payload = try? JSONDecoder().decode(SDPPayload.self, from: body) else {
            respond(connection, status: 400, body: nil)
            return
        }
        respond(connection, status: 200, body: nil) { [weak self] in
            self?.onAnswerReceived?(payload)
            // One-shot: we're done after the first successful answer.
            self?.stop()
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data?, completion: (() -> Void)? = nil) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default: statusText = "Internal Server Error"
        }
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body?.count ?? 0)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        response += "Access-Control-Allow-Headers: Content-Type\r\n"
        response += "Connection: close\r\n\r\n"

        var responseData = Data(response.utf8)
        if let body { responseData.append(body) }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }
}
