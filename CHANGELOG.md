# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org).

## [1.1.0] - 2026-09-23

### Added

- Port commands. Type `port 3000`, `kill 5173`, or `:8080` to see which process listens on that local TCP port, then press Return twice to stop it. `ports` lists every listener.
- Built-in commands: Sleep Display, Sleep Mac, Toggle Dark Mode, Show and Hide Hidden Files, Restart Finder, Restart Dock, Empty Trash, Eject All Disks, Mute and Unmute Sound, Screenshot Area to Clipboard, Copy Local IP Address, and Keep Mac Awake for 1 Hour. They run fixed programs with fixed arguments and no shell.
- Your own commands in Settings › Search › Your commands. Type a command's name to run it with `zsh -lc` from your home folder.
- Disruptive actions, such as Empty Trash and stopping a process, need a second Return. The strip says what will happen.

### Changed

- Jev now reads every request after a short pause, typed or spoken, not only long phrases. Sums, typed URLs, keyword searches, and port lookups skip it because they already have one answer. A whole-name match you typed stays first.
- Jev can choose built-in commands, your own commands by name, and the port command. It never sees or writes command text.
- Jev requests are smaller: at most 120 candidates, with favourite, recent, and running apps first.
- While voice input listens, the MacBook's built-in speakers are muted, so their sound is not transcribed. They come back when listening stops. Headphones and other outputs are not changed.

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
