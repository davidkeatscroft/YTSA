import SwiftUI

@main
struct YTSAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runner: Runner
    @StateObject private var scheduler: Scheduler

    init() {
        let runner = Runner(store: AccountStore())
        _runner = StateObject(wrappedValue: runner)
        _scheduler = StateObject(wrappedValue: Scheduler(runner: runner))
        AppDelegate.runner = runner
    }

    var body: some Scene {
        Window("YTSA", id: "main") {
            ContentView(runner: runner, store: runner.store, scheduler: scheduler)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var runner: Runner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Stay running with the window closed so scheduled runs still happen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        Self.runner?.quitBrowserNow()
    }
}
