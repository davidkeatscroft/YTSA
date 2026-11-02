import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var runner: Runner
    @ObservedObject var store: AccountStore
    @State private var viewingSlot = 0

    @AppStorage(SettingsKey.videoURL) private var videoURL = ""
    @AppStorage(SettingsKey.watchMinutes) private var watchMinutes = 10
    @AppStorage(SettingsKey.gapSeconds) private var gapSeconds = 30
    @AppStorage(SettingsKey.repeatHours) private var repeatHours = 0
    @AppStorage(SettingsKey.muted) private var muted = true

    private var shownSlot: Int { runner.currentSlot ?? viewingSlot }

    var body: some View {
        HSplitView {
            Form {
                Section("Accounts") {
                    ForEach(0..<AccountStore.slotCount, id: \.self) { slot in
                        AccountRow(slot: slot, store: store, isShown: shownSlot == slot) {
                            viewingSlot = slot
                            let wv = store.webView(slot: slot)
                            if wv.url == nil || wv.url?.absoluteString == "about:blank" {
                                wv.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
                            }
                        }
                        .disabled(runner.isRunning)
                    }
                }

                Section("Playback") {
                    TextField("YouTube video URL or ID", text: $videoURL)
                    if !videoURL.isEmpty && Runner.watchURL(from: videoURL) == nil {
                        Text("Not a recognised YouTube link").font(.caption).foregroundStyle(.red)
                    }
                    Stepper("Watch for \(watchMinutes) min per account", value: $watchMinutes, in: 1...240)
                    Stepper("Wait \(gapSeconds) s before next login", value: $gapSeconds, in: 0...3600, step: 5)
                    Stepper(repeatHours == 0 ? "Run once" : "Repeat every \(repeatHours) h",
                            value: $repeatHours, in: 0...168)
                    Toggle("Mute video", isOn: $muted)
                }
                .disabled(runner.isRunning)

                Section {
                    HStack {
                        if runner.isRunning {
                            Button("Stop", role: .destructive) { runner.stop() }
                        } else {
                            Button("Start rotation") { runner.start() }
                                .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runner.status)
                        if runner.secondsRemaining > 0 {
                            Text(Self.format(runner.secondsRemaining))
                                .font(.title2.monospacedDigit())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, idealWidth: 420, maxWidth: 520)

            VStack(spacing: 0) {
                HStack {
                    Text("Account \(shownSlot + 1)").font(.headline)
                    Text(store.emails[shownSlot]).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                Divider()
                WebViewHost(webView: store.webView(slot: shownSlot))
            }
            .frame(minWidth: 640, minHeight: 520)
        }
    }

    static func format(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct AccountRow: View {
    let slot: Int
    @ObservedObject var store: AccountStore
    let isShown: Bool
    let onShow: () -> Void

    // Holds only what the user is typing right now; cleared the moment it is saved.
    @State private var newPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $store.enabled[slot]).labelsHidden()
                Text("\(slot + 1)").font(.headline).frame(width: 16)
                TextField("email@gmail.com", text: $store.emails[slot])
                    .textContentType(.username)
                Button(isShown ? "Showing" : "Show", action: onShow)
                    .disabled(isShown)
            }
            HStack {
                SecureField(store.hasPassword[slot] ? "•••••••• saved — type to replace" : "Password",
                            text: $newPassword)
                    .textContentType(.password)
                    .onSubmit(save)
                Button("Save", action: save).disabled(newPassword.isEmpty)
                Menu {
                    Button("Forget password", role: .destructive) { store.clearPassword(slot: slot) }
                        .disabled(!store.hasPassword[slot])
                    Button("Sign out (wipe session)", role: .destructive) {
                        Task { await store.resetSession(slot: slot) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.leading, 44)
        }
        .padding(.vertical, 2)
    }

    private func save() {
        store.setPassword(newPassword, slot: slot)
        newPassword = ""
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
