# Releasing

Releases are built, signed, and notarized on a Mac. The signing certificate never goes to GitHub.

## One-time setup

1. **Developer ID certificate.** At [developer.apple.com](https://developer.apple.com/account/resources/certificates/list), create a **Developer ID Application** certificate (Account Holder role needed) and install it in your login keychain. Check it with `security find-identity -v -p codesigning`.
2. **Notary profile.** Create an app-specific password at [account.apple.com](https://account.apple.com), then run:

   ```sh
   xcrun notarytool store-credentials jev-launcher-notary --apple-id <apple-id> --team-id <team-id>
   ```

3. **GitHub CLI.** `gh auth status` must show a login with the `repo` scope.
4. **Homebrew tap.** A public repository named `homebrew-tap` with a `Casks/` folder.

## Each release

1. Set the version: `scripts/release.sh --version 1.1.0`.
2. Add a `## [1.1.0] - YYYY-MM-DD` section to `CHANGELOG.md`, or replace `Unreleased` with the date.
3. Commit both files.
4. Run `scripts/release.sh --draft-release`. It runs the tests, builds, signs, notarizes, staples, runs the Gatekeeper checks, pushes the tag, and creates a draft release with `Jev-Launcher.dmg` and its checksum.
5. Do the hands-on checks below with the DMG from `dist/`.
6. Publish the draft on GitHub.
7. Copy `dist/jev-launcher.rb` to `Casks/jev-launcher.rb` in the tap repository and push it.

The website needs no change. Its download link always points to the newest release.

To check packaging without signing, run `scripts/release.sh --unsigned --skip-tests`. Never publish that DMG.

## Hands-on checks

Unit tests cannot prove these. Do them on a Mac with a real keyboard, and record which ones you did.

**First run, on a macOS user account that has never run the app:**

- [ ] The DMG opens with no Gatekeeper warning, and the app opens from Applications with no warning.
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
