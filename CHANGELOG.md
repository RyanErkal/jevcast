# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org).

## [1.5.1] - 2026-09-25

### Fixed

- **Faster Calendar.** Month and week views fetch the months either side in the background and keep them after the view closes, so ↑, ↓, and switching to Week show at once. The List view and calendar search read events off the main thread, and Copy Details no longer reloads the list.

## [1.5.0] - 2026-09-24

### Added

- **Views in the launcher.** Mail, Calendar, Tasks, Clipboard, and Clean Up open inside the panel instead of a separate window. The search field becomes the view's filter, Escape goes back one level, and ⌘O opens Mail in its own window.
- **Mail with a preview.** The inbox list on the left and the message on the right, half and half. ↑ and ↓ move through messages, a previewed message is marked read after a second, ⌫ deletes, and Return opens it in Apple Mail. Unread messages show a dot and a bold sender. The inbox refreshes by itself while it is open.
- **Calendar views.** Month (the default), Week, and List. ← and → switch views, ↑ and ↓ move to the previous or next month or week. Events show in their calendar's colour, all-day events as a bar, and today in red.
- **Functions with `/`.** Type `/` to list everything Jevcast can do, in groups, with one line on what each does. `/cal` filters the list, Tab completes, and Return runs it. `/` followed by a real path, such as `/Applications`, still opens the folder.
- **Your library with `$`.** `$` lists only your own commands, workflows, and snippets. `$120` is still an ordinary search.
- **Time zones.** "6pm atlanta time in uk time", "3pm uk in pst", or "now in tokyo" converts a time between places. Return copies the answer, and Jev understands looser wording.
- **Dictation.** Hold Right Command, speak, and let go: the text goes into the app in front. Speech is transcribed on this Mac, audio is never saved or sent, and an optional Luna clean-up has its own switch. "dictation history" lists what you said. Off by default; turn it on in Settings › Dictation.
- **Clean up.** "cleanup" or "cool down" lists background work to stop: booted simulators, dev servers idle for an hour or more, dev processes left over from closed terminals or agents, and Docker Desktop with no containers. Heavy processes are listed but never checked. T3 Code, Chrome, Codex, Finder, Mail, your terminals, the app in front, everything those apps started, launchd jobs, and system processes are never offered. Manual only. ⌘K offers Stop Now and Always Ignore.
- **Library export and import.** Settings › Library saves your commands, workflows, snippets, search keywords, and app aliases as one file. Import shows every command's full text first and adds only what is new.
- **Hide from Search** on apps, and names that match without spaces, such as "t3code".

### Changed

- **A simpler menu bar menu.** Open, then Mail, Clean Up, and Luna Task Results. A warning row shows only when a feature you turned on needs a permission or a key.
- **Settings, reorganised.** Tabs are General, Search, Library, Windows, Voice, Dictation, AI, and Mail. General lists every permission in one place and every feature that uses the network. AI holds Jev, Luna, and Usage. Long explanations moved behind ⓘ.
- The "Jev picked … Press ⌘Z to undo" strip is gone. A Jev pick shows "Jev · ⌘Z" on its row instead.

### Fixed

- Scrolling with a trackpad or mouse wheel did nothing inside the launcher.
- Mail actions failed with an AppleScript syntax error.
- Apps, links, and files Jevcast opens come to the front.

## [1.4.0] - 2026-09-24

### Added

- **Scheduled Luna tasks.** Type a schedule and a request, such as "every weekday at 8am brief me on my meetings and unread email", "summarise my reminders every evening at 7", or "every 2 hours check my unread mail". Tasks run on this Mac while Jevcast is open, read only the data they name and you allow, and post a notification with the result. Click it to read the whole result. Each result is saved as Markdown in `~/Library/Application Support/Jevcast/Luna Tasks`. "task results" lists past runs; "scheduled tasks" lists tasks with Run Now, Pause, and Delete. A run missed by more than three hours is skipped and noted.
- **Calendar and reminders** and **Unread mail list** switches in Settings › Luna, for tasks that read events, reminders, or unread mail. Both are off at first, and the single-message mail switch does not allow the unread list.
- **Jev in two steps.** Jev also names the kind of request in a second small call at the same time. When the kind disagrees with the pick, Jev chooses again among every candidate of that kind. A window move that loosely names a running app asks which app. On by default; turn it off in Settings › Input.

### Changed

- One click runs a row, and the pointer highlights the row under it. Double-click is no longer needed.
- With nothing typed, the launcher is the search bar alone. Favourites still rank higher in results.

### Fixed

- A square light edge could show around the launcher's rounded corners in Dark Mode.

## [1.3.0] - 2026-09-24

### Added

- **Things on your Mac, with verbs.** Rows from each source below have their own actions. Return runs the first one, and ⌘K lists all of them.
- **Scheduled tasks.** "scheduled tasks", "what runs at login", or "cron" lists launch agents, daemons, crontab lines, and timers. Each row shows its schedule in plain words, the next run, whether it runs or failed, and warnings for a missing program or an unusual folder. Agents can run now, turn off, or turn on. "scheduled tasks failing" shows only jobs whose last run failed.
- **Calendar and Reminders.** "calendar", "agenda", or "my day" lists events. Join Call opens Zoom, Meet, or Teams links. Your own events move 15 minutes or an hour later. "reminders" lists open reminders, overdue first, to complete or move to tomorrow.
- **Make reminders and events.** "remind me to call mum at 5pm", "remind me to stretch in 20 minutes", and "add event lunch with Sam friday 1pm".
- **Contacts.** "contact sam" finds a person to email, message, call, or copy.
- **Browser tabs and history.** "tabs" lists tabs in Safari, Chrome, Arc, Brave, Edge, Vivaldi, and Dia, to switch to, close, or copy. One row closes duplicate tabs. "history <words>" searches browser history on this Mac.
- **This.** Type "this", or an action such as "copy link", to act on the page, Finder selection, or selected text in front: copy a link, make a reminder, open the page in another browser, or compress files.
- **Luna.** An opt-in writing model, GPT-6 Luna through OpenRouter, with Fast, High, and Max effort. "ask …" answers a question in the panel. With selected text, Luna fixes, shortens, rewrites, summarises, explains, or translates it, and Return replaces the selection. Jev decides what a request means; Luna only writes text.
- **Mail.** "mail" or "inbox" opens a keyboard-first mail window on top of Apple Mail: Inbox, Unread, Flagged, each account's mailboxes, a message list, and a reading pane. Archive, delete, move, flag, reply, forward, and new messages go through Apple Mail, which starts hidden. Luna can summarise a message or draft a reply. "mail <words>" searches from the launcher.
- **Settings › Luna.** Effort, an OpenRouter key, a switch for each kind of context Luna may read, and an activity log of each request without its text.
- `--diagnose-source '<query>'` and `--diagnose-mail` for checks on a real Mac.

### Privacy

- Luna is off until you turn it on. Selected text and mail go to Luna only when you turn on each one. Jevcast checks every request against those switches before it sends it.
- HTML mail shows with scripts off, and every remote load is blocked, so tracking pixels do not load.
- Jevcast reads Apple Mail, Calendar, Reminders, Contacts, browser tabs, and browser history on this Mac only. Each needs its own macOS permission.

## [1.2.3] - 2026-09-23

### Changed

- ⌫ stops a port's process, not Return, and the launcher stays open. The first ⌫ asks and the second stops. The row disappears and the strip says what stopped. ⌫ stops only after you pick the row with ↑↓ or a click, so typing still deletes text. ⌘⌫ stops the selected process at any time.
- Return on a port opens `http://localhost:<port>` in your browser.
- ⌘K on a port adds Stop, next to Force Stop.

## [1.2.2] - 2026-09-23

### Added

- A richer port list. Each listening process shows its CPU, memory, uptime, the script or module it runs (such as `vite` or `http.server`), its project folder, and whether it is open to your network or to this Mac only. The numbers refresh every two seconds while the list is open.
- Your own servers come first. macOS services are marked and warn that they may start again. Another user's processes, such as root's, cannot be stopped from here: Return explains why, and ⌘K copies the `sudo kill` command.
- ⌘K on a port: open `http://localhost:<port>`, show the folder in Finder, force stop, copy the PID, or copy the full command line.

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
