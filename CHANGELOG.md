# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org).

## [1.2.1] - 2026-09-23

### Added

- Jev through OpenRouter. Paste an OpenRouter key (`sk-or-…`) in Settings › Input and Jevcast sends Jev requests to OpenRouter's proxy of the TypeSafe API, with the model `typesafe/jev-1.13`. A TypeSafe key still goes to TypeSafe directly.
- Settings › Usage shows the cost OpenRouter reports for each request. TypeSafe requests are priced from their tokens.
- `--store-jev-key` saves a key from standard input.

### Fixed

- A reply from a dated Jev build, such as `typesafe/jev-1.13-20260917`, was rejected.
- An account without credits (HTTP 402) now says so.

## [1.2.0] - 2026-09-23

### Added

- **Settings › Usage.** Jev requests, input and output tokens, cost, Jev picks, and requests answered from memory, for 7 days, 30 days, and all time. Counts come from TypeSafe's usage figures and stay on this Mac.
- **Memory.** When you choose a result for a request, Jevcast remembers it on this Mac. The same request then needs no Jev call. ⌘Z on a remembered or Jev pick undoes it and forgets it.
- **Open and arrange.** "notes left half" or "open notes on the left" opens the app, then arranges its window.
- **Site search in plain words.** "search github for swift ui". Jev can also pick a site, and the rest of the request becomes the search.
- **Apple Shortcuts.** Your Shortcuts appear in the launcher, and Jev can choose them.
- **Menu items.** The menus of the app you were using, such as Safari's "New Private Window", are searchable. The Window menu and recent-document menus are left out.
- **Workflows** in Settings › Commands: run several steps from one name, such as open Xcode, Left Two Thirds, open Terminal, Right Third.
- **Snippets** with `{date}`, `{time}`, and `{clipboard}`. Shift–Return pastes.
- **Timers.** `5m tea`, `timer 10 min`, or "remind me in 20 minutes to call Sam". Type `timers` to cancel one.
- **Emoji and symbols.** `:tada`, `emoji party`, or `symbol arrow`. Return copies, Shift–Return pastes.
- **Calculator history.** Use `ans` in a sum, such as `ans * 2`. Type `history` for recent answers.
- **Clipboard.** Pin items from the ⌘K menu, filter with `clip links`, `clip numbers`, `clip colours`, `clip emails`, or `clip code`, and paste with Shift–Return.
- **Ports.** Plain phrasing such as "stop whatever is running on 3000". ⌘K adds Force Stop and Copy PID.
- **Your commands** can take text: put `{input}` in the command, then type the name and the text. `{input}` is passed as a quoted argument, never as command text. A command can copy its output or show it in a notification.
- `--diagnose-jev "request"` runs requests through the launcher with the stored key and prints the pick and the tokens used.

### Changed

- Jev is smarter about when to run. A whole-name match, a sum, a URL, a keyword search, a timer, or a port lookup skips it. The same request within 10 minutes reuses the last answer.
- Jev's candidate list puts matches for the request's words first, from apps, System Settings panes, commands, workflows, Shortcuts, snippets, and menu items. It can also route to Find Files, Recent Files, Clipboard History, and Timers.
- File search understands more everyday phrasing: "pdfs from last week in downloads", "documents I changed last month", "screenshots from yesterday". New dates: last week, this month, last month.
- Your commands moved to a new Settings › Commands tab with workflows and snippets.
- Local builds are signed with your Apple Development certificate when you have one, so macOS keeps Accessibility access across rebuilds.

### Fixed

- A sum with a spaced division, such as `100 / 4`, was read as a file path.
- A custom command with a lot of output could hang.

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
