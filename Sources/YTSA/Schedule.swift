import AppKit
import Foundation
import ServiceManagement

struct Schedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case once, daily, weekly, monthlyDay, monthlyWeekday
        var id: Self { self }
        var title: String {
            switch self {
            case .once: "Once"
            case .daily: "Every day"
            case .weekly: "Every week"
            case .monthlyDay: "Monthly, on a date"
            case .monthlyWeekday: "Monthly, on a weekday"
            }
        }
    }

    var enabled = false
    var kind: Kind = .daily
    var hour = 3
    var minute = 0
    /// Day to run for `.once` (time comes from hour/minute).
    var onceDate = Date()
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int> = [2]
    /// 1…31, or 0 for the last day of the month. Days past the month's end run on its last day.
    var dayOfMonth = 1
    /// 1…4 for first…fourth, -1 for last.
    var ordinal = -1
    var weekday = 6

    static let ordinals: [(Int, String)] = [(1, "First"), (2, "Second"), (3, "Third"), (4, "Fourth"), (-1, "Last")]

    func nextRun(after now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0..<800 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  matches(day, calendar),
                  let run = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  run > now else { continue }
            return run
        }
        return nil
    }

    private func matches(_ day: Date, _ calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.day, .weekday], from: day)
        guard let dom = c.day, let wd = c.weekday,
              let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count else { return false }
        switch kind {
        case .once:
            return calendar.isDate(day, inSameDayAs: onceDate)
        case .daily:
            return true
        case .weekly:
            return weekdays.contains(wd)
        case .monthlyDay:
            return dom == (dayOfMonth == 0 ? daysInMonth : min(dayOfMonth, daysInMonth))
        case .monthlyWeekday:
            guard wd == weekday else { return false }
            return ordinal == -1 ? dom + 7 > daysInMonth : (dom - 1) / 7 + 1 == ordinal
        }
    }

    var summary: String {
        let symbols = Calendar.current.weekdaySymbols
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .once:
            return "Once on \(onceDate.formatted(date: .abbreviated, time: .omitted)) at \(time)"
        case .daily:
            return "Every day at \(time)"
        case .weekly:
            let days = weekdays.sorted().map { symbols[$0 - 1] }
            return days.isEmpty ? "Pick at least one day" : "Every \(days.joined(separator: ", ")) at \(time)"
        case .monthlyDay:
            return dayOfMonth == 0 ? "Last day of every month at \(time)"
                : "Day \(dayOfMonth) of every month at \(time)"
        case .monthlyWeekday:
            let ord = Self.ordinals.first { $0.0 == ordinal }?.1.lowercased() ?? ""
            return "The \(ord) \(symbols[weekday - 1]) of every month at \(time)"
        }
    }
}

/// Starts the runner when the schedule comes due. YTSA has to be open (it can open at
/// login) and the Mac awake; a run missed by more than an hour is skipped, not caught up.
@MainActor
final class Scheduler: ObservableObject {
    @Published var schedule: Schedule {
        didSet {
            if let data = try? JSONEncoder().encode(schedule) {
                UserDefaults.standard.set(data, forKey: "schedule")
            }
            recompute()
        }
    }
    @Published private(set) var nextRun: Date?
    @Published private(set) var lastEvent: String?
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    private let runner: Runner
    private var timer: Timer?
    private var noNap: NSObjectProtocol?

    init(runner: Runner) {
        self.runner = runner
        schedule = UserDefaults.standard.data(forKey: "schedule")
            .flatMap { try? JSONDecoder().decode(Schedule.self, from: $0) } ?? Schedule()
        recompute()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func recompute() {
        nextRun = schedule.enabled ? schedule.nextRun(after: Date()) : nil
        // Keep App Nap from delaying the timer while a run is scheduled.
        if nextRun != nil, noNap == nil {
            noNap = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "YTSA scheduled run")
        } else if nextRun == nil, let noNap {
            ProcessInfo.processInfo.endActivity(noNap)
            self.noNap = nil
        }
    }

    private func tick() {
        guard let due = nextRun, Date() >= due else { return }
        let when = due.formatted(date: .abbreviated, time: .shortened)
        if runner.isRunning {
            lastEvent = "Skipped \(when): a run was already in progress"
        } else if Date().timeIntervalSince(due) > 3600 {
            lastEvent = "Skipped \(when): the Mac was asleep or YTSA was closed"
        } else {
            lastEvent = "Started scheduled run for \(when)"
            runner.start()
        }
        if schedule.kind == .once { schedule.enabled = false } else { recompute() }
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastEvent = "Couldn't change open-at-login: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
