import AppKit
import Foundation

enum SettingsKey {
    static let videoURL = "videoURL"
    static let watchMinutes = "watchMinutes"
    static let gapSeconds = "gapSeconds"
    static let repeatHours = "repeatHours"
    static let muted = "muted"
}

/// Rotates through the enabled accounts: make sure each is signed in, open the
/// chosen video in that account's browser for the watch time, quit, wait the gap, move on.
@MainActor
final class Runner: ObservableObject {
    let store: AccountStore

    @Published private(set) var isRunning = false
    @Published private(set) var currentSlot: Int?
    @Published private(set) var status = "Idle"
    @Published private(set) var secondsRemaining = 0

    private var task: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?
    private var browser: Process?

    init(store: AccountStore) { self.store = store }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "YTSA rotation")
        task = Task { [weak self] in
            await self?.runLoop()
            await self?.finish()
        }
    }

    func stop() {
        task?.cancel()
    }

    /// For app quit, where there's no time to wait.
    func quitBrowserNow() {
        browser?.terminate()
    }

    private func finish() async {
        if let browser { await Browser.quit(browser) }
        browser = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
        currentSlot = nil
        isRunning = false
        secondsRemaining = 0
        store.refreshStatus()
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
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
        if let open = slots.first(where: { Browser.isOpen(slot: $0) }) {
            status = "Error: close the browser window for account \(open + 1) first"
            return
        }

        do {
            repeat {
                for (i, slot) in slots.enumerated() {
                    currentSlot = slot
                    let label = "Account \(slot + 1)"

                    if !Browser.isSignedIn(slot: slot) {
                        try await signIn(slot: slot)
                    }

                    status = "\(label): watching"
                    browser = try Browser.launch(slot: slot, url: videoURL, muted: muted)
                    try await countdown(watch)
                    if let browser { await Browser.quit(browser) }
                    browser = nil
                    store.refreshStatus()

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
            status = "Done — all accounts watched (\(Self.timeFormatter.string(from: Date())))"
        } catch is CancellationError {
            status = "Stopped"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func countdown(_ seconds: Int) async throws {
        for elapsed in 0..<seconds {
            secondsRemaining = seconds - elapsed
            try await Task.sleep(for: .seconds(1))
        }
        secondsRemaining = 0
    }

    // MARK: - Sign-in

    /// Opens the account's browser on Google sign-in and fills in the saved email and
    /// password. Anything Google asks after that (2FA, "is it you?") is left to you.
    private func signIn(slot: Int) async throws {
        let label = "Account \(slot + 1)"
        status = "\(label): signing in…"
        let port = Int.random(in: 20000...40000)
        let process = try Browser.launch(slot: slot, url: Browser.youtubeSignInURL(email: store.email(slot)),
                                         debugPort: port)
        browser = process
        let cdp = try await CDP.connect(port: port)
        defer { cdp.close() }

        if try await waitFor(cdp, Self.visible("input[type=email]"), timeout: 10) {
            try await focus(cdp, "input[type=email]")
            try await cdp.typeAndSubmit(store.email(slot))
        }
        if store.hasPassword[slot],
           try await waitFor(cdp, Self.visible("input[type=password]"), timeout: 15) {
            try await focus(cdp, "input[type=password]")
            _ = try await PasswordVault.withPassword(slot: slot) { password in
                try await cdp.typeAndSubmit(password)
            }
        }

        let started = Date()
        var alerted = false
        while Date().timeIntervalSince(started) < 300 {
            try await Task.sleep(for: .seconds(2))
            guard process.isRunning else {
                throw Failure(errorDescription: "\(label)'s browser was closed before sign-in finished")
            }
            if (try? await cdp.cookieNames(for: "https://www.youtube.com"))?.contains("LOGIN_INFO") == true {
                cdp.close()
                await Browser.quit(process)
                browser = nil
                return
            }
            // Still not signed in after a few seconds means Google wants a human step.
            if !alerted, Date().timeIntervalSince(started) > 12 {
                alerted = true
                status = "\(label): finish sign-in / verification in the browser"
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
        throw Failure(errorDescription: "\(label) didn't finish signing in within 5 minutes")
    }

    private static func visible(_ selector: String) -> String {
        "(() => { const e = document.querySelector('\(selector)'); return !!(e && e.offsetParent !== null); })()"
    }

    private func focus(_ cdp: CDP, _ selector: String) async throws {
        _ = try await cdp.evaluate("(() => { const e = document.querySelector('\(selector)'); e?.focus(); e?.select?.(); })()")
    }

    private func waitFor(_ cdp: CDP, _ js: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await cdp.evaluate(js)) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

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
