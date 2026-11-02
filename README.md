# YTSA (YouTube Sucks Ass)

A native macOS app that rotates through up to six YouTube accounts on one Mac,
playing a chosen video in each for a set time, on demand or on a schedule.

## Requirements

- macOS 14 (Sonoma) or later
- Google Chrome (Brave, Microsoft Edge or Chromium also work)
- To build from source: Xcode or the Command Line Tools (`xcode-select --install`)

## Build

```bash
./build.sh
```

This builds a universal (Apple Silicon + Intel) `YTSA.app` and a shareable
`dist/YTSA.zip`. See the top of the script for Developer ID signing and notarization.

## Opening a shared copy

The shared zip is not notarized by Apple, so macOS blocks it the first time:

1. Unzip `YTSA.zip` and drag `YTSA.app` into Applications.
2. Double-click it. When macOS says it can't be opened, click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to the YTSA message. Confirm with your Mac password.

After that it opens normally.

## Using it

**Accounts tab**
1. Enter each account's email, and optionally its password (press **Save**).
2. Open the **⋯** menu → **Sign in in browser** for each account and sign in
   once, approving any 2FA. Close that browser window when done; the badge
   turns to **Signed in**.

Each account uses its own private Chrome profile (stored in
`~/Library/Application Support/YTSA/Profiles`), separate from your normal Chrome.

**Playback tab**: the video (link or ID), minutes to watch per account, wait
between logins, optional repeat, mute.

**Schedule tab**: run once, every day, on chosen weekdays, on a day of the month
(or the last day), or on "the first/second/third/fourth/last [weekday] of every
month". YTSA must be open (closing its window is fine) and the Mac awake at
that time; turn on **Open YTSA when I log in** so it's always running. A run
missed by more than an hour is skipped.

To wake a sleeping Mac for a run, schedule a wake a few minutes earlier, e.g.:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 02:55:00
```

**Start now** runs immediately. If an account isn't signed in, YTSA opens its
browser on Google sign-in and fills in the saved email and password. If Google
asks for verification, finish it in that window; YTSA waits up to five minutes.

## Password security

- Passwords are stored only in the macOS Keychain, readable only while the Mac
  is unlocked and never synced to other devices.
- The app has no way to display a saved password; the field is write-only.
- The only code that reads a password is sign-in auto-fill, which types it into
  Google's password box as keyboard input over Chrome's local remote-control
  port. That port is open only during the sign-in step.
- Anyone signed in to the same macOS user can still view the Keychain entry in
  Keychain Access after entering the Mac password.

## Keeping 2FA prompts rare

- Sign in by hand once per account and don't wipe the browser profiles.
- Tick "Don't ask again on this device" when Google offers it.
- Prefer phone prompts over codes.
- Always run on the same Mac and home network.

Note: making accounts appear to be in your household when they aren't is against
YouTube Premium Family terms, and the risk falls on those accounts.
