# YTSA (YouTube Sucks Ass)

A native macOS app that rotates through up to six YouTube accounts on one Mac,
playing a chosen video in each for a set time.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```bash
./build.sh
open YTSA.app
```

`build.sh` compiles a release build and wraps it in `YTSA.app` (ad-hoc signed).

## Using it

1. Enter an email and password for each account (up to six) and press **Save**.
2. Click **Show** on each account and sign in by hand once, approving any 2FA.
   Each account has its own persistent browser session, so later runs reuse it.
3. Set the video (URL, youtu.be link, or video ID), watch minutes, wait between
   logins, and optional repeat interval.
4. Press **Start rotation**.

If Google asks for verification during a run, the app pauses for up to five
minutes and bounces its Dock icon until you finish it in the window.

## Password security

- Passwords are stored only in the macOS Keychain, readable only while the Mac
  is unlocked and never synced to other devices.
- The app has no way to display a saved password; the field is write-only.
- The only code that reads a password is the sign-in automation, which passes it
  to Google's login form in an isolated script context.
- Anyone signed in to the same macOS user can still view the Keychain entry in
  Keychain Access after entering the Mac password.

## Keeping 2FA prompts rare

- Sign in manually once per account and don't wipe sessions.
- Tick "Don't ask again on this device" when Google offers it.
- Prefer phone prompts over codes.
- Always run on the same Mac and home network.

Note: making accounts appear to be in your household when they aren't is against
YouTube Premium Family terms, and the risk falls on those accounts.
