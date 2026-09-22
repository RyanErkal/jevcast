# Releasing

The public install route is the source repository:
`https://github.com/RyanErkal/jevcast`.

## Before publishing

1. Set the version with `scripts/release.sh --version 1.1.0`.
2. Add a `## [1.1.0] - YYYY-MM-DD` section to `CHANGELOG.md`, or replace
   `Unreleased` with the date.
3. Run `swift test`.
4. Run `scripts/build.sh` on a Mac with Xcode 26 or later.
5. Verify the built app with:

   ```sh
   codesign --verify --deep --strict --verbose=2 "dist/Jevcast.app"
   ```

6. Do the hands-on checks below with the built app from `dist/`.
7. Publish the source and release notes on GitHub.

The website and README must keep the source install prompt current. Keep
release notes accurate about the artifacts that are available.

## Hands-on checks

Unit tests cannot prove these. Do them on a Mac with a real keyboard, and record which ones you did.

**First run, on a macOS user account that has never run the app:**

- [ ] The app opens from `/Applications` without bypassing Gatekeeper or
      changing macOS security settings.
- [ ] The welcome window opens by itself, and the "try it" line turns green after the shortcut opens the launcher.
- [ ] Accessibility, Microphone, and Speech Recognition prompts open the right System Settings pages.
- [ ] Open at login works after a restart.

**Launcher:**

- [ ] The shortcut opens the launcher with search focused, and the first typed characters are kept.
- [ ] Escape closes the launcher, the actions menu, and Quick Look.
- [ ] An outside click closes the launcher and does not press what is under it. Check a second display and a full-screen Space.
- [ ] Other apps get no typing, clicks, or scrolling while the launcher is open.
- [ ] Cancelling returns to the previous app. Opening an app or file keeps focus on it.
- [ ] Nothing stays on screen after closing, switching apps, an error, or a display change.
- [ ] The menu-bar icon is clear in light and dark menu bars, and shows a dot when an update is available.

**Features:**

- [ ] Window actions and direct shortcuts move real windows, including on a second display.
- [ ] Voice input transcribes speech and stops when you type.
- [ ] With a TypeSafe key, a loose request such as "make this window bigger" selects a window action.
- [ ] **Check for Updates…** reports the right result.
- [ ] `port <n>` lists a real local server, and two Returns stop it.
- [ ] A built-in command, such as Toggle Dark Mode, runs. Empty Trash asks for a second Return.
- [ ] A command added in Settings › Search runs from the launcher.
- [ ] With voice on and sound playing through the built-in speakers, the speakers mute while listening and come back after. Headphones are not muted.
