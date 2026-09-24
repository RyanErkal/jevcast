# Development

## Layout

The package has two targets.

- `Sources/LauncherCore`: pure logic with no AppKit, so tests are fast and exact. Calculator and unit conversion, time zone conversion (`TimeZoneQuery.swift`, with the bundled place table in `TimeZonePlaces.swift`), file-query parsing, search ranking, frecency, window geometry, the built-in command list (`SystemCommands.swift`), port-query and `lsof` parsing (`Ports.swift`), Jev usage totals, learned requests, timer parsing, emoji, and query text helpers. Tests are in `Tests/LauncherCoreTests`.
- `Sources/JevLauncher`: the app.
  - `App.swift`: app delegate, global shortcuts, open and close, snapshot runs.
  - `LauncherModel.swift`: builds, ranks, and runs results.
  - `LauncherPanel.swift`, `LauncherView.swift`, `ResultList.swift`: the panel. It is a non-activating key panel, so typing works without activating the app.
  - `LauncherPages.swift`, `SourcePage.swift`, `PageSources.swift`, `MailPage.swift`: views that fill the panel in place of the results: Mail, Calendar, Tasks, Clipboard, and Clean Up. The search field filters the view, Escape goes back one level, and ⌘O opens Mail in its own window. The panel grows to 860×700 for a view.
  - `FileSearch.swift`: Spotlight queries inside the configured folders.
  - `WindowManager.swift`: Accessibility window moves, snapping, and undo.
  - `LauncherModel+Commands.swift`: command, custom-command, and port rows.
  - `CommandRunner.swift`: runs built-in commands without a shell, the user's own commands with `zsh -lc`, and `lsof`.
  - `SpeechService.swift`: on-device speech recognition.
  - `SpeakerGuard.swift`: mutes the built-in speakers while the microphone listens.
  - `LauncherModel+Jev.swift`: when to ask Jev, memory, the reply cache, candidate ranking, routes, and undo.
  - `LauncherModel+Functions.swift`: "/" function rows and "$" library rows. `FunctionCatalog.swift` in LauncherCore lists the functions and reads the prefixes.
  - `LauncherModel+Clock.swift`: the time zone answer row, and the Jev path for loose wording. Jev picks only the two places from a fixed list; code reads the time and does the math.
  - `LauncherModel+Extras.swift`: workflows, Shortcuts, snippets, timers, menu items, emoji, calculator history, and open-then-arrange.
  - `JevUsageLog.swift`, `SettingsUsage.swift`: token and cost counts for Settings › AI › Usage.
  - `MenuScanner.swift`, `Notifier.swift`, `UserItems.swift`: front-app menus, local notifications and timers, and the user's commands, workflows, and snippets.
  - `JevService.swift`: Jev selection through TypeSafe or OpenRouter, chosen by the key. Validates every reply before use.
  - `UpdateService.swift`, `UpdateChecker.swift`: the daily GitHub release check.
  - `Settings*.swift`, `WelcomeWindow.swift`, `StatusMenu.swift`, `AppMenus.swift`: windows and menus. Settings tabs: General (permissions, network), Search, Library (`SettingsCommands.swift`, export and import in `LibraryFile.swift`), Windows, Voice, AI (`SettingsAI.swift`: Jev, Luna, Usage), and Mail.
  - `AppIdentity.swift`: name, bundle ID, and project links.
  - `Thing.swift`, `Sources.swift`: rows with their own verbs, and sources that load them for a query such as "scheduled tasks". `SourceQuery.swift` in LauncherCore reads the keywords.
  - `ScheduledSource.swift`: launchd jobs, crontab, and timers. `ScheduledJobs.swift` in LauncherCore parses plists and cron lines and computes the next run.
  - `OrganizerSources.swift`, `LauncherModel+Create.swift`: Calendar, Reminders, and Contacts through EventKit and Contacts. `CreateQuery.swift` reads "remind me …" and "add event …".
  - `BrowserSources.swift`, `FrontContext.swift`: tabs, history, and "this". `BrowserTabs.swift` in LauncherCore holds the fixed AppleScript for each browser.
  - `LunaService.swift`, `LauncherModel+Luna.swift`, `SettingsLuna.swift`: Luna through OpenRouter, the context switches, and the activity log. `LunaPrompt.swift` in LauncherCore builds each request.
  - `Mail*.swift`: the mail window. `MailStore.swift` reads Apple Mail's index and `.emlx` files; `MailActions.swift` changes mail through Apple Mail; `MIMEMessage.swift` and `MailIndex.swift` in LauncherCore parse messages and hold Mail's fixed AppleScript.
  - `SQLiteReader.swift`: a read-only SQLite reader with bound values.
  - `LunaTaskCenter.swift`, `LunaTaskViews.swift`, `TaskRunsSource.swift`: scheduled Luna tasks, their results, and the result window. `LunaTasks.swift` in LauncherCore parses schedules and decides when a task is due.
  - `JevLayers.swift` in LauncherCore: the kinds of request for layered Jev matching, and how the two first answers are combined.

## Rename the app

Change `AppIdentity.swift` and the `APP_NAME` and `BUNDLE_ID` lines in `scripts/build.sh`. `AppIdentityTests` fails if the two disagree. Then search for the old name in `Sources`, `site`, and the documents. A new bundle ID starts with empty preferences and a new Keychain item.

## Diagnostic flags

Run the executable inside the app bundle, for example `"dist/Jevcast.app/Contents/MacOS/JevLauncher" --diagnose`.

| Flag                                       | Result                                                                                                 |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `--diagnose`                               | Prints catalogue size, first results for sample queries, and search timings. Opens nothing.            |
| `--diagnose-files 'kind:pdf in:downloads'` | Prints file-search results from your folders for five seconds.                                         |
| `--diagnose-source 'scheduled tasks'`      | Prints the rows and verbs a source query lists. Runs nothing. Tabs may ask for Automation access.       |
| `--diagnose-mail`                          | Checks that Apple Mail can be read. Prints counts and column names only, never subjects or addresses.  |
| `--diagnose-jev 'request' …`               | Runs each request through the launcher with the stored TypeSafe key and prints the pick, the top row, and the tokens used. Billed, and counted in Settings › AI › Usage. |
| `echo KEY \| … --store-jev-key`            | Saves a TypeSafe or OpenRouter key in the Keychain from standard input, as Settings › AI › Jev does. The key is never an argument or printed. |
| `--open`                                   | Shows the launcher at launch.                                                                          |
| `--welcome`                                | Shows the welcome window at launch.                                                                    |
| `--trace-latency`                          | Prints panel and result timings. No query text.                                                        |
| `--trace-interaction`                      | Prints open, close, focus, and resize events. No query text.                                           |
| `--snapshot-ui <dir>`                      | Renders the launcher states, each panel view, each Settings pane, and the welcome window to PNG files, then quits. Mail, Calendar, and Clean Up views render empty. |
| `--snapshot-ui <dir> --demo`               | The same, with invented sample files, Apple apps only, and fresh settings. Use this for public images. |

Snapshots render the app's own views. They show layout only, not window material, shadows, or the toolbar. Snapshot windows stay transparent and never take focus, clicks, or typing.

`scripts/window-fixture.sh` opens two disposable windows for window-action checks. Avoid Tile All and Cascade All during these checks, because they move every eligible window on the display.

## Icon

`swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns` and the Icon Composer bundle `Resources/AppIcon.icon`. `scripts/build.sh` compiles the bundle with `xcrun actool`, so macOS 26 shows a Liquid Glass icon. Without actool it ships the `.icns`.

## Build notes

- `scripts/build.sh` builds arm64 and x86_64 by default. `ARCHS=arm64` builds one architecture.
- The build records the real SDK version in the binary. Without it, macOS 26 draws standard windows in the older style. The minimum system stays macOS 14.
- The bundle is assembled in `dist/.stage.*` and then moved into place, so a running copy is never changed in place.
- A local build is signed with your first "Apple Development" certificate when one is in the keychain. macOS then keeps Accessibility, Microphone, and Speech access across rebuilds. Without one, the build is signed ad hoc, and each rebuild needs access granted again: remove the old Jevcast entry in System Settings › Privacy & Security › Accessibility, then add it again.

## Website

`site/` is the landing page: static HTML, CSS, and one small script, with no build step and no third-party requests. The display font is self-hosted under the SIL Open Font License (`site/fonts/OFL.txt`).

- Preview: `python3 -m http.server 4388 --directory site`, then open `http://localhost:4388`.
- Images: the launcher states in `site/images/launcher-*.png` come from `--snapshot-ui <dir> --demo`. Replace them only with demo renders.
- Deploy: the Vercel project `jevcast` uses `site` as its root folder, so deploy from a folder that contains only `site/` and the project link: copy `site/` and `site/.vercel` into an empty folder, then run `vercel deploy --prod` there. Deploying from the repository root uploads build folders. `site/vercel.json` sets the security headers.
- The download link points to the newest GitHub release, so a release needs no website change.
