import Foundation
import SQLite3

/// Each account gets its own Chrome (or other Chromium browser) profile folder.
/// Google allows sign-in in a real browser, unlike in a web view embedded in an app,
/// and each profile keeps its own long-lived session cookies.
enum Browser {
    private static let candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "\(NSHomeDirectory())/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]

    static var executable: URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static var name: String? { executable?.lastPathComponent }

    struct NotInstalled: LocalizedError {
        var errorDescription: String? { "Google Chrome isn't installed (Brave, Edge or Chromium also work)" }
    }

    static func profileDir(slot: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YTSA/Profiles/Account \(slot + 1)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True while a browser window for this profile is open.
    static func isOpen(slot: Int) -> Bool {
        let lock = profileDir(slot: slot).appendingPathComponent("SingletonLock").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: lock)) != nil
    }

    /// `debugPort` opens Chrome's local remote-control port, which sign-in auto-fill needs.
    /// It is only used for the sign-in step; watching runs without it.
    static func launch(slot: Int, url: URL, muted: Bool = false, debugPort: Int? = nil) throws -> Process {
        guard let exe = executable else { throw NotInstalled() }
        var args = [
            "--user-data-dir=\(profileDir(slot: slot).path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--autoplay-policy=no-user-gesture-required",
            "--hide-crash-restore-bubble",
        ]
        if muted { args.append("--mute-audio") }
        if let debugPort { args.append("--remote-debugging-port=\(debugPort)") }
        args.append(url.absoluteString)

        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Quits gracefully so the profile's cookies are written to disk.
    static func quit(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<40 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Reads the profile's cookie database (names only, values stay encrypted) to see
    /// whether YouTube's session cookie is present and unexpired.
    static func isSignedIn(slot: Int) -> Bool {
        let dir = profileDir(slot: slot)
        // Chrome stores cookies as microseconds since 1601-01-01.
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        for rel in ["Default/Network/Cookies", "Default/Cookies"] {
            let file = dir.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            guard sqlite3_open_v2(file.absoluteString + "?immutable=1", &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { continue }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT COUNT(*) FROM cookies
                WHERE host_key LIKE '%youtube.com' AND name = 'LOGIN_INFO'
                AND (expires_utc = 0 OR expires_utc > ?)
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, now)
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int(stmt, 0) > 0 { return true }
        }
        return false
    }

    /// Deletes the whole profile, signing the account out of YTSA's browser.
    static func wipe(slot: Int) {
        try? FileManager.default.removeItem(at: profileDir(slot: slot))
    }

    static let youtubeSignInURL: URL = {
        var comps = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        comps.queryItems = [
            .init(name: "service", value: "youtube"),
            .init(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=%2F"),
        ]
        return comps.url!
    }()

    static func youtubeSignInURL(email: String) -> URL {
        var comps = URLComponents(url: youtubeSignInURL, resolvingAgainstBaseURL: false)!
        comps.queryItems?.append(.init(name: "Email", value: email))
        return comps.url!
    }
}
