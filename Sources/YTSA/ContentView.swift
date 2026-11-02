import SwiftUI

struct ContentView: View {
    @ObservedObject var runner: Runner
    @ObservedObject var store: AccountStore
    @ObservedObject var scheduler: Scheduler

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                AccountsTab(store: store)
                    .tabItem { Text("Accounts") }
                PlaybackTab()
                    .tabItem { Text("Playback") }
                ScheduleTab(scheduler: scheduler)
                    .tabItem { Text("Schedule") }
            }
            .disabled(runner.isRunning)
            .padding([.horizontal, .top])

            Divider().padding(.top, 8)
            StatusBar(runner: runner)
        }
        .frame(minWidth: 600, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshStatus()
        }
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        Form {
            Section {
                ForEach(0..<AccountStore.slotCount, id: \.self) { slot in
                    AccountRow(slot: slot, store: store)
                }
            } footer: {
                if let name = Browser.name {
                    Text("Each account signs in with its own private \(name) profile. Sign in once with “Sign in in browser”, then the saved session is reused.")
                } else {
                    Text("YTSA needs Google Chrome (or Brave, Edge, Chromium) installed.")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountRow: View {
    let slot: Int
    @ObservedObject var store: AccountStore

    // Holds only what you're typing right now; cleared the moment it's saved.
    @State private var newPassword = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Use account \(slot + 1)", isOn: $store.enabled[slot])
                    .labelsHidden()
                Text("\(slot + 1)").font(.headline).frame(width: 14)
                TextField("Email", text: $store.emails[slot], prompt: Text("email@gmail.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity)
                statusBadge
            }
            HStack(spacing: 8) {
                SecureField("Password", text: $newPassword,
                            prompt: Text(store.hasPassword[slot] ? "•••••••• saved — type to replace" : "Password"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit(save)
                    .frame(maxWidth: .infinity)
                Button("Save", action: save).disabled(newPassword.isEmpty)
                Menu {
                    Button("Sign in in browser") {
                        do { try store.openForManualSignIn(slot: slot) } catch { self.error = error.localizedDescription }
                    }
                    .disabled(store.browserOpen[slot])
                    Divider()
                    Button("Forget password", role: .destructive) { store.clearPassword(slot: slot) }
                        .disabled(!store.hasPassword[slot])
                    Button("Sign out (wipe browser profile)", role: .destructive) { store.wipeSession(slot: slot) }
                        .disabled(store.browserOpen[slot])
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.leading, 52)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 52)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusBadge: some View {
        if store.browserOpen[slot] {
            Label("Browser open", systemImage: "macwindow").foregroundStyle(.orange)
                .font(.caption).fixedSize()
        } else if store.signedIn[slot] {
            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.caption).fixedSize()
        } else {
            Label("Not signed in", systemImage: "circle").foregroundStyle(.secondary)
                .font(.caption).fixedSize()
        }
    }

    private func save() {
        store.setPassword(newPassword, slot: slot)
        newPassword = ""
    }
}

// MARK: - Playback

struct PlaybackTab: View {
    @AppStorage(SettingsKey.videoURL) private var videoURL = ""
    @AppStorage(SettingsKey.watchMinutes) private var watchMinutes = 10
    @AppStorage(SettingsKey.gapSeconds) private var gapSeconds = 30
    @AppStorage(SettingsKey.repeatHours) private var repeatHours = 0
    @AppStorage(SettingsKey.muted) private var muted = true

    var body: some View {
        Form {
            Section {
                TextField("Video", text: $videoURL, prompt: Text("YouTube link or video ID"))
                    .textFieldStyle(.roundedBorder)
                if !videoURL.isEmpty && Runner.watchURL(from: videoURL) == nil {
                    Text("Not a recognised YouTube link").font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Stepper("Watch for \(watchMinutes) min per account", value: $watchMinutes, in: 1...240)
                Stepper("Wait \(gapSeconds) s before the next login", value: $gapSeconds, in: 0...3600, step: 5)
                Stepper(repeatHours == 0 ? "Go through the accounts once" : "Repeat every \(repeatHours) h",
                        value: $repeatHours, in: 0...168)
                Toggle("Mute video", isOn: $muted)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Schedule

struct ScheduleTab: View {
    @ObservedObject var scheduler: Scheduler

    private var s: Binding<Schedule> { $scheduler.schedule }
    private let symbols = Calendar.current.weekdaySymbols
    private let shortSymbols = Calendar.current.shortWeekdaySymbols

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: scheduler.schedule.hour,
                                  minute: scheduler.schedule.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            scheduler.schedule.hour = c.hour ?? 0
            scheduler.schedule.minute = c.minute ?? 0
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Run on a schedule", isOn: s.enabled)
            }
            Section {
                Picker("Repeat", selection: s.kind) {
                    ForEach(Schedule.Kind.allCases) { Text($0.title).tag($0) }
                }
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)

                switch scheduler.schedule.kind {
                case .once:
                    DatePicker("Date", selection: s.onceDate, in: Calendar.current.startOfDay(for: Date())...,
                               displayedComponents: .date)
                case .daily:
                    EmptyView()
                case .weekly:
                    LabeledContent("Days") {
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { wd in
                                Toggle(shortSymbols[wd - 1], isOn: Binding {
                                    scheduler.schedule.weekdays.contains(wd)
                                } set: { on in
                                    if on { scheduler.schedule.weekdays.insert(wd) }
                                    else { scheduler.schedule.weekdays.remove(wd) }
                                })
                                .toggleStyle(.button)
                            }
                        }
                    }
                case .monthlyDay:
                    Picker("Day", selection: s.dayOfMonth) {
                        ForEach(1...31, id: \.self) { Text(Self.ordinalDay($0)).tag($0) }
                        Divider()
                        Text("Last day").tag(0)
                    }
                    if scheduler.schedule.dayOfMonth > 28 {
                        Text("In shorter months this runs on the month's last day.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .monthlyWeekday:
                    Picker("Which", selection: s.ordinal) {
                        ForEach(Schedule.ordinals, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Weekday", selection: s.weekday) {
                        ForEach(1...7, id: \.self) { Text(symbols[$0 - 1]).tag($0) }
                    }
                }
            } footer: {
                Text(scheduler.schedule.summary)
            }
            .disabled(!scheduler.schedule.enabled)

            Section {
                LabeledContent("Next run") {
                    if let next = scheduler.nextRun {
                        Text(next.formatted(date: .complete, time: .shortened))
                    } else {
                        Text(scheduler.schedule.enabled ? "None" : "Off").foregroundStyle(.secondary)
                    }
                }
                if let event = scheduler.lastEvent {
                    LabeledContent("Last", value: event)
                }
                Toggle("Open YTSA when I log in", isOn: Binding {
                    scheduler.opensAtLogin
                } set: { scheduler.setOpensAtLogin($0) })
            } footer: {
                Text("YTSA must be open (closing the window is fine) and the Mac awake at the scheduled time. A run missed by more than an hour is skipped.")
            }
        }
        .formStyle(.grouped)
    }

    static func ordinalDay(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }
}

// MARK: - Status

struct StatusBar: View {
    @ObservedObject var runner: Runner

    var body: some View {
        HStack(spacing: 12) {
            if runner.isRunning {
                Button("Stop", role: .destructive) { runner.stop() }
                    .controlSize(.large)
            } else {
                Button("Start now") { runner.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Text(runner.status)
                .lineLimit(2)
                .foregroundStyle(runner.status.hasPrefix("Error") ? .red : .primary)
            Spacer()
            if runner.secondsRemaining > 0 {
                Text(Self.format(runner.secondsRemaining))
                    .font(.title2.monospacedDigit())
            }
        }
        .padding()
    }

    static func format(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }
}
