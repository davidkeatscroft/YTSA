import Foundation

/// Minimal Chrome DevTools Protocol client over the local remote-control port.
@MainActor
final class CDP {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let socket: URLSessionWebSocketTask
    private var nextID = 0

    private init(url: URL) {
        socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 16 << 20
        socket.resume()
    }

    /// Waits for the browser to come up and attaches to its first tab.
    static func connect(port: Int, timeout: TimeInterval = 20) async throws -> CDP {
        let list = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (data, _) = try? await URLSession.shared.data(from: list),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let page = targets.first(where: { $0["type"] as? String == "page" }),
               let ws = (page["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) {
                return CDP(url: ws)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure(errorDescription: "Couldn't connect to the browser to fill in the sign-in form")
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let raw: Data
            switch try await socket.receive() {
            case .string(let s): raw = Data(s.utf8)
            case .data(let d): raw = d
            @unknown default: continue
            }
            // Skip events and replies to other requests.
            guard let msg = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  msg["id"] as? Int == id else { continue }
            if let error = msg["error"] as? [String: Any] {
                throw Failure(errorDescription: error["message"] as? String ?? "Browser error")
            }
            return msg["result"] as? [String: Any] ?? [:]
        }
    }

    func evaluate(_ js: String) async throws -> Any? {
        let r = try await send("Runtime.evaluate", ["expression": js, "returnByValue": true, "awaitPromise": true])
        return (r["result"] as? [String: Any])?["value"]
    }

    func cookieNames(for url: String) async throws -> Set<String> {
        let r = try await send("Network.getCookies", ["urls": [url]])
        let cookies = r["cookies"] as? [[String: Any]] ?? []
        return Set(cookies.compactMap { $0["name"] as? String })
    }

    /// Types into the focused field as real keyboard input, then presses Return.
    /// The text goes straight to the browser's input system, never into page script.
    func typeAndSubmit(_ text: String) async throws {
        try await send("Input.insertText", ["text": text])
        try await Task.sleep(for: .milliseconds(300))
        let key: [String: Any] = ["key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13]
        try await send("Input.dispatchKeyEvent", key.merging(["type": "keyDown", "text": "\r"]) { $1 })
        try await send("Input.dispatchKeyEvent", key.merging(["type": "keyUp"]) { $1 })
    }

    func close() {
        socket.cancel(with: .goingAway, reason: nil)
    }
}
