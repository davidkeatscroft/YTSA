import Foundation

/// Six account slots. Emails live in UserDefaults; passwords only in the Keychain.
/// Browser sessions live in each slot's own browser profile (see `Browser`).
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
    @Published private(set) var signedIn: [Bool]
    @Published private(set) var browserOpen: [Bool]

    private var manualWindows: [Int: Process] = [:]

    init() {
        let saved = defaults.stringArray(forKey: "emails") ?? []
        emails = (0..<Self.slotCount).map { $0 < saved.count ? saved[$0] : "" }
        let savedEnabled = defaults.array(forKey: "enabled") as? [Bool] ?? []
        enabled = (0..<Self.slotCount).map { $0 < savedEnabled.count ? savedEnabled[$0] : true }
        hasPassword = (0..<Self.slotCount).map { PasswordVault.exists(slot: $0) }
        signedIn = Array(repeating: false, count: Self.slotCount)
        browserOpen = Array(repeating: false, count: Self.slotCount)
        refreshStatus()
    }

    func refreshStatus() {
        signedIn = (0..<Self.slotCount).map { Browser.isSignedIn(slot: $0) }
        browserOpen = (0..<Self.slotCount).map { Browser.isOpen(slot: $0) }
    }

    func setPassword(_ password: String, slot: Int) {
        guard !password.isEmpty else { return }
        hasPassword[slot] = PasswordVault.save(password, slot: slot)
    }

    func clearPassword(slot: Int) {
        PasswordVault.delete(slot: slot)
        hasPassword[slot] = PasswordVault.exists(slot: slot)
    }

    func email(_ slot: Int) -> String {
        emails[slot].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isConfigured(_ slot: Int) -> Bool {
        enabled[slot] && !email(slot).isEmpty
    }

    /// Opens the account's browser profile on Google sign-in so you can log in by hand.
    func openForManualSignIn(slot: Int) throws {
        let url = email(slot).isEmpty ? Browser.youtubeSignInURL : Browser.youtubeSignInURL(email: email(slot))
        let process = try Browser.launch(slot: slot, url: url)
        manualWindows[slot] = process
        browserOpen[slot] = true
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.manualWindows[slot] = nil
                self?.refreshStatus()
            }
        }
    }

    func wipeSession(slot: Int) {
        guard !Browser.isOpen(slot: slot) else { return }
        Browser.wipe(slot: slot)
        refreshStatus()
    }
}
