import AppKit
import Foundation
import WebKit

enum SettingsKey {
    static let videoURL = "videoURL"
    static let watchMinutes = "watchMinutes"
    static let gapSeconds = "gapSeconds"
    static let repeatHours = "repeatHours"
    static let muted = "muted"
}

/// Rotates through the enabled accounts: make sure each is signed in, play the
/// chosen video for the watch time, wait the gap, move on.
@MainActor
final class Runner: ObservableObject {
    let store: AccountStore

    @Published private(set) var isRunning = false
    @Published private(set) var currentSlot: Int?
    @Published private(set) var status = "Idle"
    @Published private(set) var secondsRemaining = 0

    private var task: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?

    init(store: AccountStore) { self.store = store }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "YTSA rotation")
        task = Task { [weak self] in
            await self?.runLoop()
            self?.finish()
        }
    }

    func stop() {
        task?.cancel()
    }

    private func finish() {
        if let slot = currentSlot { pauseVideo(store.webView(slot: slot)) }
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
        isRunning = false
        secondsRemaining = 0
        if !status.hasPrefix("Error") { status = "Stopped" }
    }

    // MARK: - Loop

    private func runLoop() async {
        let d = UserDefaults.standard
        guard let videoURL = Self.watchURL(from: d.string(forKey: SettingsKey.videoURL) ?? "") else {
            status = "Error: set a valid YouTube video URL or ID"
            return
        }
        let watch = max(1, d.integer(forKey: SettingsKey.watchMinutes)) * 60
        let gap = max(0, d.integer(forKey: SettingsKey.gapSeconds))
        let repeatHours = max(0, d.integer(forKey: SettingsKey.repeatHours))
        let muted = d.bool(forKey: SettingsKey.muted)

        let slots = (0..<AccountStore.slotCount).filter { store.isConfigured($0) }
        guard !slots.isEmpty else {
            status = "Error: no enabled accounts with an email"
            return
        }

        do {
            repeat {
                for (i, slot) in slots.enumerated() {
                    currentSlot = slot
                    let wv = store.webView(slot: slot)
                    let label = "Account \(slot + 1)"

                    status = "\(label): checking sign-in…"
                    if try await !isSignedIn(wv) {
                        try await signIn(slot: slot, wv: wv)
                    }

                    status = "\(label): watching"
                    wv.load(URLRequest(url: videoURL))
                    try await waitForLoad(wv)
                    try await countdown(watch) { elapsed in
                        if elapsed % 15 == 0 { self.ensurePlaying(wv, muted: muted) }
                    }
                    pauseVideo(wv)

                    if i < slots.count - 1 && gap > 0 {
                        status = "Next login in…"
                        try await countdown(gap)
                    }
                }
                if repeatHours > 0 {
                    status = "Cycle done. Next cycle in…"
                    try await countdown(repeatHours * 3600)
                }
            } while repeatHours > 0
            status = "Done — all accounts watched"
        } catch is CancellationError {
            status = "Stopped"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func countdown(_ seconds: Int, tick: ((Int) -> Void)? = nil) async throws {
        for elapsed in 0..<seconds {
            secondsRemaining = seconds - elapsed
            tick?(elapsed)
            try await Task.sleep(for: .seconds(1))
        }
        secondsRemaining = 0
    }

    // MARK: - Sign-in

    private func isSignedIn(_ wv: WKWebView) async throws -> Bool {
        wv.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
        try await waitForLoad(wv)
        try await Task.sleep(for: .seconds(2))
        let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookies()
        let hasCookie = cookies.contains { $0.domain.hasSuffix("youtube.com") && $0.name == "LOGIN_INFO" }
        let showsSignInButton = (try? await wv.evaluateJavaScript(
            "!!document.querySelector('a[href*=\"ServiceLogin\"], ytd-button-renderer a[aria-label=\"Sign in\"]')"
        )) as? Bool ?? false
        return hasCookie && !showsSignInButton
    }

    private struct SignInError: LocalizedError {
        let errorDescription: String?
    }

    private func signIn(slot: Int, wv: WKWebView) async throws {
        let label = "Account \(slot + 1)"
        let email = store.emails[slot].trimmingCharacters(in: .whitespaces)
        var comps = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        comps.queryItems = [
            .init(name: "service", value: "youtube"),
            .init(name: "Email", value: email),
            .init(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=%2F"),
        ]
        status = "\(label): signing in…"
        wv.load(URLRequest(url: comps.url!))
        try await waitForLoad(wv)

        if try await waitFor(wv, Self.visible("input[type=email]"), timeout: 10) {
            _ = try await fill(wv, field: "input[type=email]", value: email,
                               next: ["#identifierNext button", "#identifierNext"])
        }

        if store.hasPassword[slot],
           try await waitFor(wv, Self.visible("input[type=password]"), timeout: 15) {
            _ = try await PasswordVault.withPassword(slot: slot) { password in
                try await self.fill(wv, field: "input[type=password]", value: password,
                                    next: ["#passwordNext button", "#passwordNext"])
            }
        }

        // Whatever Google asks next (2FA, "is it you?", captcha) the user completes in the window.
        let started = Date()
        var alerted = false
        while Date().timeIntervalSince(started) < 300 {
            try await Task.sleep(for: .seconds(2))
            let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookies()
            if cookies.contains(where: { $0.domain.hasSuffix("youtube.com") && $0.name == "LOGIN_INFO" }) {
                return
            }
            // Still not signed in after a few seconds means Google wants a human step.
            if !alerted, Date().timeIntervalSince(started) > 12 {
                alerted = true
                status = "\(label): finish sign-in / verification in the window"
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
        throw SignInError(errorDescription: "\(label) did not finish signing in within 5 minutes")
    }

    // MARK: - Page helpers

    private static func visible(_ selector: String) -> String {
        "(() => { const e = document.querySelector('\(selector)'); return !!(e && e.offsetParent !== null); })()"
    }

    private func waitForLoad(_ wv: WKWebView, timeout: TimeInterval = 30) async throws {
        try await Task.sleep(for: .milliseconds(300))
        _ = try await waitFor(wv, "document.readyState === 'complete'", timeout: timeout)
    }

    private func waitFor(_ wv: WKWebView, _ js: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !wv.isLoading, (try? await wv.evaluateJavaScript(js)) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Values are passed as call arguments (never spliced into script text) and run in an
    /// isolated content world, so page scripts can't read them off our function.
    private func fill(_ wv: WKWebView, field: String, value: String, next: [String]) async throws -> Bool {
        let js = """
        const el = document.querySelector(field);
        if (!el) return false;
        el.focus();
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        await new Promise(r => setTimeout(r, 400));
        for (const s of next) { const b = document.querySelector(s); if (b) { b.click(); return true; } }
        el.form?.requestSubmit?.();
        return true;
        """
        let result = try await wv.callAsyncJavaScript(
            js, arguments: ["field": field, "value": value, "next": next],
            in: nil, contentWorld: .defaultClient)
        return result as? Bool ?? false
    }

    private func ensurePlaying(_ wv: WKWebView, muted: Bool) {
        wv.evaluateJavaScript("""
        (() => { const v = document.querySelector('video'); if (!v) return;
          v.muted = \(muted); if (v.paused) v.play().catch(() => {}); })()
        """)
    }

    private func pauseVideo(_ wv: WKWebView) {
        wv.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
    }

    /// Accepts a full YouTube URL, a youtu.be link, or a bare 11-character video ID.
    static func watchURL(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var id: String?
        if s.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            id = s
        } else if let url = URL(string: s), let host = url.host?.lowercased() {
            if host.hasSuffix("youtu.be") {
                id = url.pathComponents.dropFirst().first
            } else if host.hasSuffix("youtube.com") {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                id = comps?.queryItems?.first(where: { $0.name == "v" })?.value
                    ?? (url.pathComponents.count > 2 ? url.pathComponents[2] : nil) // /shorts/ID, /live/ID
            }
        }
        guard let id, !id.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)&autoplay=1")
    }
}
