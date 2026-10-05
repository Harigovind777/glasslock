import AppKit
import GlassLockCore

/// Streams the ntfy topic, turns `lock` messages into callbacks, and publishes acks.
@MainActor
final class RelayClient {
    enum Status: Equatable {
        case connecting
        case connected
        case waiting(seconds: Int)
    }

    var onStatus: (Status) -> Void = { _ in }
    var onLock: (String) -> Void = { _ in }

    private let base: URL
    private var topic: String
    private let session: URLSession
    /// One filter for the app's lifetime: dedupe and resume point survive reconnects.
    private var filter = RelayMessageFilter()
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(topic: String, base: URL = URL(string: "https://ntfy.sh")!) {
        self.topic = topic
        self.base = base
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90 // ntfy sends a keepalive every ~45 s
        config.timeoutIntervalForResource = 60 * 60 * 24 * 365
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func start() {
        restartLoop()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.write("relay: woke from sleep, reconnecting")
                    self?.restartLoop()
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    func change(topic: String) {
        self.topic = topic
        filter = RelayMessageFilter()
        restartLoop()
    }

    func sendAck(_ kind: AckKind, commandID: String) {
        var request = URLRequest(url: base.appendingPathComponent("\(topic)-ack"))
        request.httpMethod = "POST"
        request.httpBody = Data("\(kind.rawValue):\(commandID)".utf8)
        let session = self.session
        Task {
            for attempt in 1...2 {
                do {
                    let (_, response) = try await session.data(for: request)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        Log.write("relay: ack \(kind.rawValue) \(commandID)")
                        return
                    }
                } catch {
                    Log.write("relay: ack attempt \(attempt) failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            onStatus(.connecting)
            do {
                let (bytes, response) = try await session.bytes(for: streamRequest())
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                onStatus(.connected)
                Log.write("relay: connected")
                backoff.reset()
                for try await line in bytes.lines {
                    switch filter.decide(line: line, now: Date()) {
                    case .lock(let id):
                        Log.write("relay: lock \(id)")
                        onLock(id)
                    case .ignore(let reason):
                        if !reason.hasPrefix("event:") {
                            Log.write("relay: ignored (\(reason))")
                        }
                    }
                }
                Log.write("relay: stream ended")
            } catch {
                if Task.isCancelled { return }
                Log.write("relay: \(error.localizedDescription)")
            }
            if Task.isCancelled { return }
            let delay = backoff.nextDelay()
            onStatus(.waiting(seconds: Int(delay)))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func streamRequest() -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("\(topic)/json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: filter.resumeToken)]
        return URLRequest(url: components.url!)
    }
}
