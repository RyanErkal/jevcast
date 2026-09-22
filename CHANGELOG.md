# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org).

## [1.0.0] - 2026-09-22

First public source release. Build on a Mac with Xcode 26 or later. No signed binary is included.

### Added

- A welcome window on first launch: choose a shortcut and try it, allow Accessibility, turn on voice, open at login, and check for updates. It warns if the app runs from the disk image or Downloads. **Help › Welcome Guide** opens it again.
- **Check for Updates…** in the app menu and the menu bar. An automatic check runs once a day and can be turned off in Settings › General. The app never downloads or installs updates itself.
- A **Help** menu with the welcome guide, the website, the source code, and issue reporting. About shows the license.
- One universal app for Apple silicon and Intel Macs.
- Settings › Input explains natural-language matching and links to TypeSafe for a key.

### Changed

- The public-facing app name is now Jevcast, and the repository is `RyanErkal/jevcast`. Internal bundle and executable identifiers stay stable.
- The shortcut on a new install is Option–Space. Earlier installs keep the shortcut they had.
- Voice input starts off on a new install. Earlier installs keep their setting.
- On macOS 26, Settings and the welcome window use the current system design.
- Preferences, the Keychain item, and logs share one identifier. A stored TypeSafe key moves to the new Keychain item automatically.

### Fixed

- The six sixth-of-screen window actions showed no icon.
- A sum or conversion no longer lists window actions or settings that share one word with it, such as "Left Two Thirds" for `12 * (8 + 2)`.
