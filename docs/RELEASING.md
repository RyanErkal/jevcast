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
- [ ] `port <n>` lists a real local server with CPU and memory. Picking it and pressing ⌫ twice stops it, and the launcher stays open.
- [ ] A built-in command, such as Toggle Dark Mode, runs. Empty Trash asks for a second Return.
- [ ] A command added in Settings › Search runs from the launcher.
- [ ] `notes left half` with Notes closed opens Notes, then arranges it.
- [ ] A Jev pick shows "Jev" beside it, ⌘Z undoes it, and the same request next time says "Remembered".
- [ ] Settings › Usage counts a Jev request.
- [ ] A menu item of the front app, a Shortcut, a workflow, a snippet (Shift–Return pastes), a timer notification, and `:tada` all work.
- [ ] With voice on and sound playing through the built-in speakers, the speakers mute while listening and come back after. Headphones are not muted.

**Sources, Luna, and Mail:**

- [ ] `scheduled tasks` lists your agents with plain-words schedules. Turn Off and Turn On change a test agent, and the row updates.
- [ ] `calendar` and `reminders` ask for access once, then list items. Join Call opens a meeting link. Complete removes a reminder.
- [ ] `remind me to test in 2 minutes` makes a reminder that notifies. `add event test tomorrow 3pm` adds an event.
- [ ] `contact <name>` lists a person. Email opens the Jevcast compose window.
- [ ] `tabs` in Safari, Chrome, and Dia asks for Automation once, lists tabs, and Switch to Tab and Close Tab act on the right tab.
- [ ] With a page open, `copy link` copies it. Opening the launcher over a browser without typing shows no Automation prompt.
- [ ] With Luna on and an OpenRouter key: `ask what is 2+2` answers. With Selected text on, Fix Spelling replaces a selection in TextEdit. With it off, no selected-text request is sent, and Settings › Luna logs each request.
- [ ] `mail` without Full Disk Access shows the setup view. With it, the Inbox lists messages. Archive, Delete, Flag, Reply, and a new message act on the right message in Apple Mail.
- [ ] An HTML newsletter shows without remote images, and a link opens in the browser.
- [ ] One click on a row runs it. Moving the pointer highlights rows; a still pointer does not change the selection while ↑↓ move it. The empty launcher shows only the bar, and no square edge shows at its corners in Dark Mode.
- [ ] `every day at <two minutes from now> give me a quote` schedules a task. A notification arrives on time, a click opens the result, and `task results` lists it. With Mail off in Settings › Luna, a mail task reports that it needs the switch and sends nothing.
- [ ] With layered matching on, `put the chrom one on the left` moves Chrome, and Settings › Usage counts the extra calls.
