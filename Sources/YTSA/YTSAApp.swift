import SwiftUI

@main
struct YTSAApp: App {
    @StateObject private var runner = Runner(store: AccountStore())

    var body: some Scene {
        Window("YTSA", id: "main") {
            ContentView(runner: runner, store: runner.store)
        }
        .windowResizability(.contentMinSize)
    }
}
