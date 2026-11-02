import Foundation
import WebKit

/// Six account slots. Emails live in UserDefaults; passwords only in the Keychain.
/// Each slot also owns a persistent, isolated WebKit profile so its Google
/// session cookies survive between runs (this is what keeps 2FA prompts rare).
@MainActor
final class AccountStore: ObservableObject {
    static let slotCount = 6
    private let defaults = UserDefaults.standard

    @Published var emails: [String] {
        didSet { defaults.set(emails, forKey: "emails") }
    }
    @Published var enabled: [Bool] {
        didSet { defaults.set(enabled, forKey: "enabled") }
    }
    @Published private(set) var hasPassword: [Bool]

    private var webViews: [Int: WKWebView] = [:]

    init() {
        let saved = defaults.stringArray(forKey: "emails") ?? []
        emails = (0..<Self.slotCount).map { $0 < saved.count ? saved[$0] : "" }
        let savedEnabled = defaults.array(forKey: "enabled") as? [Bool] ?? []
        enabled = (0..<Self.slotCount).map { $0 < savedEnabled.count ? savedEnabled[$0] : true }
        hasPassword = (0..<Self.slotCount).map { PasswordVault.exists(slot: $0) }
    }

    func setPassword(_ password: String, slot: Int) {
        guard !password.isEmpty else { return }
        hasPassword[slot] = PasswordVault.save(password, slot: slot)
    }

    func clearPassword(slot: Int) {
        PasswordVault.delete(slot: slot)
        hasPassword[slot] = PasswordVault.exists(slot: slot)
    }

    func isConfigured(_ slot: Int) -> Bool {
        enabled[slot] && !emails[slot].trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func profileID(slot: Int) -> UUID {
        let key = "profile.\(slot)"
        if let s = defaults.string(forKey: key), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }

    func webView(slot: Int) -> WKWebView {
        if let wv = webViews[slot] { return wv }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileID(slot: slot))
        config.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: .zero, configuration: config)
        // Google refuses sign-in from embedded browsers it doesn't recognise; present as Safari.
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        webViews[slot] = wv
        return wv
    }

    /// Signs the slot out locally by wiping its WebKit profile.
    func resetSession(slot: Int) async {
        let store = webView(slot: slot).configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        webView(slot: slot).load(URLRequest(url: URL(string: "about:blank")!))
    }
}
