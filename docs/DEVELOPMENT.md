# Development

## Layout

The package has three targets.

- `Sources/LauncherCore`: pure logic with no AppKit, so tests are fast and exact. Calculator and unit conversion, time zone conversion (`TimeZoneQuery.swift`, with the bundled place table in `TimeZonePlaces.swift`), file-query parsing, search ranking, frecency, window geometry, the built-in command list (`SystemCommands.swift`), port-query and `lsof` parsing (`Ports.swift`), Jev usage totals, learned requests, timer parsing, emoji, query text helpers, and clipboard rules in `Clipboard/` (`ClipEntry`, `ClipboardSettings` with retention, `ClipClassifier` and colors, `ClipTransform`, and `ClipSearch` with the filter chips). Tests are in `Tests/LauncherCoreTests`.
- `Sources/JevRunner`: `jevcast-runner`, the background automation scheduler in `Jevcast.app/Contents/MacOS`, registered from `Contents/Library/LaunchAgents/com.ryanerkal.jevlauncher.runner.plist` (template `scripts/runner-agent.plist`). Its logic lives in `LauncherCore/Automations`: `RRule`, `Scheduler`, `AutomationStore`, `RunnerCommand`, `RunnerEvents`, `ProcessSupervisor`, `RunEngine`, `OccurrenceClaim` (one run per scheduled time, even after a crash), `WaitingRunExpiry` (a proposal left for seven days expires, so it stops blocking the next run), `OrphanRecovery` (stops a crashed runner's leftover children only when their group is provably the same; an unknown group is kept and blocks work), `StagedTask`, `StagedHandoff`, and `RunEngine+Staged` (report workflows: preflight, one fetch worker, one analyst, finish, publish), `StagedChecks` (per-client claims, leftover fetch groups, repeated-failure keys), `FetchToolServer` (the fetch worker's one MCP tool), `CodexAuth` (ChatGPT sign-in check), `AutomationSetup` (`--configure`), `ProgramIdentity` (a script must match what was saved), and `ClaudeSignIn` (gateway sign-in values for restricted Claude runs). The app side also uses `Proposal*` (check, apply, undo; `UserTags.swift` sets Finder tags on a verified file), `CodexImport*`, `AlertDecision.swift` (when a run alerts, quiet hours, alert words), `AutomationLook.swift` (the icon colours an automation may use, symbol name checks, and the kind of work hidden names show), `RunProgress.swift` (the last finished stage from a run's `stages.json`, without item names or numbers, and the needs-review and report-ready markers), `ToolLocator.swift` (where to find `codex` and `claude`, and apply summaries), `KeepAwakePolicy.swift` (when the runner keeps the Mac from idle sleep on power; `JevRunner/KeepAwake.swift` makes the IOKit assertion), and `RunPresentation.swift` (plain explanations for known failure causes, and back-to-back repeated failures folded into one list entry; display only). `jevcast-runner --root <dir>` runs it against another store folder. `jevcast-runner --configure <file> [--check]` applies a reviewed definition file (paused). `jevcast-runner --fetch-tool <spec>` is started by Codex as the fetch worker's stdio MCP server; it is not for direct use.
- `Sources/JevLauncher`: the app.
  - `App.swift`: app delegate, global shortcuts, open and close, snapshot runs.
  - `InstanceGuard.swift`: keeps one copy running. A second copy asks the first to show the launcher, then exits. An alert launch from the runner hands off without showing anything. `SingleInstance.swift` in LauncherCore makes the decision.
  - `Diagnostics*.swift`, `UISnapshots.swift`, `DemoData.swift`: the diagnostic flags and snapshot runs below.
  - `Cleanup.swift`, `CleanupSource.swift`, `CleanupProcessScan.swift`: the manual Clean Up checklist and process scan. Computer-use rows show a PID, known program names, and the parent. Attached workers and the shared service are locked. Only known workers reparented to PID 1, with no launchd job, listener, busy process, or unknown child, can be selected; they start unchecked. The group stop asks for a second Return. Regular apps, coding CLIs, IPC workers, and their child trees stay running. `Cleanup.swift` and `ComputerUseCleanup.swift` in LauncherCore classify the scan. `CleanupIdentity.swift` reads kernel executable paths, argument boundaries, owner IDs, and start times without displaying arguments. `CleanupStopPlan.swift` rejects changed selections and checks identity before each individual signal. TERM is followed by a verified KILL only for selected orphaned computer-use workers; replacement workers are left alone. A failed ownership scan offers no stop action.
  - `LauncherModel.swift`: builds, ranks, and runs results.
  - `LauncherPanel.swift`, `LauncherView.swift`, `ResultList.swift`: the panel. It is a non-activating key panel, so typing works without activating the app.
  - `Clipboard*.swift`, `ClipStyle.swift`, `ClipThumbnails.swift`, `DemoClipboard.swift`: clipboard history. `ClipboardHistory` polls the change count on the main thread; `ClipboardWorker` (an actor) reads large data, hashes, encodes, makes thumbnails, and writes `ClipboardStore` files in `~/Library/Application Support/Jevcast/Clipboard` (folder 0700, files 0600: `index.json` plus one folder of blobs per entry). `ClipboardCapture` sorts a read into an entry and finds text in images with Vision. `ClipboardPage`, `ClipboardPageView`, `ClipboardPreview`, and `ClipboardActions` are the view, its preview, and the ⌘K menu. Pasteboard access goes through `PasteboardReading`, so tests use a fake.
  - `LauncherPages.swift`, `SourcePage.swift`, `PageSources.swift`, `MailPage.swift`: views that fill the panel in place of the results: Mail, Calendar, Tasks, Clipboard, Clean Up, and Terminal. The search field filters the view, Escape goes back one level (a view opened with a Hyper key closes the launcher at its top level, and the footer says Close), and ⌘O opens Mail in its own window. The panel grows for a view, up to 1320×880 and within the screen.
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
  - `MenuScanner.swift`, `Notifier.swift`, `UserItems.swift`: front-app menus, local notifications and timers, and the user's commands, workflows, and snippets. A timer's notification carries its label and end time, so the timer list comes back from the pending notifications after a relaunch.
  - `JevService.swift`: Jev selection through TypeSafe or OpenRouter, chosen by the key. Validates every reply before use.
  - `UpdateService.swift`, `UpdateChecker.swift`: the daily GitHub release check.
  - `Settings*.swift`, `WelcomeWindow.swift`, `StatusMenu.swift`, `AppMenus.swift`: windows and menus. Settings tabs: General (permissions, network, and Clipboard in `SettingsClipboard.swift`), Keys (`SettingsKeys.swift`, `SettingsKeyReference.swift`), Search, Library (`SettingsCommands.swift`, export and import in `LibraryFile.swift`), Windows, Voice (`SettingsVoicePane.swift`: Voice input, Dictation), AI (`SettingsAI.swift`: Jev, Writing, Usage), Automations (`SettingsAutomations.swift`), and Mail.
  - `AppIdentity.swift`: name, bundle ID, and project links.
  - `Thing.swift`, `Sources.swift`: rows with their own verbs, and sources that load them for a query such as "scheduled tasks". `SourceQuery.swift` in LauncherCore reads the keywords.
  - `ScheduledSource.swift`: launchd jobs, crontab, and timers. `ScheduledJobs.swift` in LauncherCore parses plists and cron lines and computes the next run.
  - `OrganizerSources.swift`, `LauncherModel+Create.swift`: Calendar, Reminders, and Contacts through EventKit and Contacts. `CreateQuery.swift` reads "remind me …" and "add event …".
  - `BrowserSources.swift`, `FrontContext.swift`: tabs, history, and "this". `BrowserTabs.swift` in LauncherCore holds the fixed AppleScript for each browser.
  - `AIWritingService.swift`, `LauncherModel+AIWriting.swift`, `SettingsAIWriting.swift`, `AIWritingAnswerView.swift`: AI writing (Ask AI, selected text, mail, and dictation clean-up) through OpenRouter, the context switches, and the activity log. `AIWritingPrompt.swift` in LauncherCore builds each request. `AIWritingStorageKeys.swift` holds the stored names; they keep the old "luna" and "quill" spellings so settings, keys, and history survive the renames.
  - `TerminalPage.swift`, `TerminalView.swift`, `GhosttyRuntime.swift`: the Terminal view (Hyper–T). `GhosttyRuntime` is the one libghostty app and its callbacks; `TerminalView` is one surface running the login shell, with keys, mouse, and clipboard passed to libghostty. `TerminalPage` puts it in the panel: `LauncherPage.inputView` gives it the keys and `hasFilter` hides the search field; Escape still closes the view. The app delegate owns the surface, so the shell keeps running while the launcher is closed, and it is freed when the shell exits. `TerminalStyle.swift` writes the launcher look as a Ghostty config file (transparent background, margins, accent bar cursor, text and selection colours per appearance) that loads after the user's Ghostty config; `GhosttyRuntime` reloads it when the appearance changes. `ShellFolder.swift` reads the shell's folder for the bar from the process table (the child of Jevcast's `/usr/bin/login`) once a second while the view shows. The view is 35% smaller than other views (`LauncherPanel.viewSize(for:)`). It has no input method support yet.
  - `Mail*.swift`: the mail window. `MailStore.swift` reads Apple Mail's index and `.emlx` files through one read-only connection on a serial queue, with cached prepared statements. Lists use keyset pages of 200 (`date_received DESC, ROWID DESC`), one index walk per mailbox merged with `UNION ALL`; search terms are matched once against the subject, address, and summary tables. `MailPagingTests` builds a 100k-message synthetic index, checks query plans with `EXPLAIN QUERY PLAN`, and asserts timings (skipped under a sanitizer). `MailListParts.swift` holds the shared list, mailbox menu, and closed-Mail note; `MailActions.swift` changes mail through Apple Mail. `MIMEMessage.swift` parses messages, `MailIndex.swift` holds mailbox and message types, and `MailScripts.swift` plus `MailScripts+Compose.swift` hold fixed AppleScript.
  - `SQLiteReader.swift`: a read-only SQLite reader with bound values.
  - `NativeMailCenter.swift`, `SettingsMailAccounts.swift`: Jevcast's own mail accounts. The mail source (`MailBackend`: Apple Mail or Jevcast accounts), the account list in `~/Library/Application Support/Jevcast/Mail/accounts.json`, app passwords in the Keychain (`mail-<account id>`), and the running `NativeMailEngine`. With Jevcast accounts, `MailStore.status()` returns the native store and `MailActions` sends each change to the engine instead of Apple Mail.
  - `LauncherCore/NativeMail/`: the engine, with no external dependencies. `IMAPParser`, `IMAPFramer`, `IMAPCommand`, `ModifiedUTF7`, and `IMAPSequenceSet` read and write IMAP; `IMAPClient` runs one command at a time on one connection (with IDLE in `IMAPClient+Idle.swift`); `SMTPClient` sends; `MailTransport` wraps `URLSessionStreamTask`, which can start TLS on an open connection for STARTTLS. `MailComposer` writes RFC 5322 messages, and `MailReplies` builds replies and forwards. `NativeMailStore` writes a SQLite database with the tables and columns of Apple Mail's `Envelope Index` that `MailStore` reads, and `.emlx` bodies in Mail's layout, so one reader serves both. `MailAccountSync` keeps one account in step on three connections (sync, changes, IDLE). It reads only the newest mail of the inbox and of opened folders, in UID ranges sized for the server's MESSAGELIMIT, and older mail only when the list asks (`loadOlder`); `MailSyncPolicy` holds its batch sizes and intervals. `NativeMailEngine` runs every account and makes changes locally first. `MailProvider` holds the Yahoo, iCloud, Gmail, and Outlook servers. `FakeIMAPServer` and `FakeSMTPServer` in the tests stand in for real servers.
  - `AutomationCenter.swift` and `AutomationCenter+*.swift`: the app's side of automations. It watches the Automations folder and the runner signal, writes definitions and requests, maps SMAppService and the heartbeat to a runner status, finds the CLIs, checks and applies proposals, reads Codex, and shows notch alerts (`Notch/`: model, queue, controller; `NotchAlert.swift`: views). `AutomationSecrets.swift` keeps script secrets in the Keychain. `AutomationsSource.swift` is the "automations" launcher row.
  - `ScheduledBriefCenter.swift`, `ScheduledBriefViews.swift`, `TaskRunsSource.swift`: scheduled briefs, their results, and the result window. Scheduling a brief opens the scheduled tasks list in the launcher. A failed brief shows a notch alert; there are no system notifications for briefs. `ScheduledBriefs.swift` in LauncherCore parses schedules and decides when a brief is due.
  - `Dictation*.swift`, `AudioCapture.swift`, `AppleSpeechEngine.swift`, `TextInserter.swift`, `SettingsDictation.swift`: hold Right Command to dictate (macOS 26). Audio stays in memory; transcripts are JSON Lines in `~/Library/Application Support/Jevcast/Dictation/`. `DictationHold.swift`, `DictationText.swift`, and `TranscriptStore.swift` in LauncherCore hold the key state machine, local clean-up, and the history files.
  - `HyperKeyController.swift`, `HyperKeyTap.swift`, `HyperKeyRemap.swift`, `CapsLockLight.swift`, `SettingsHyperKey.swift`: the Hyper key (Settings › Keys). `hidutil` maps Caps Lock to F18 with fixed arguments and keeps other mappings; a marker in UserDefaults lets the next launch undo it after a crash. An event tap on its own thread swallows F18 and the mapped keys and hands actions to the main queue. The Caps Lock light is set through IOKit HID and may need Input Monitoring. `HyperKey.swift` in LauncherCore holds the key layer, the key state machine, and the mapping merge.
  - `JevLayers.swift` in LauncherCore: the kinds of request for layered Jev matching, and how the two first answers are combined.
  - `TailnetSource.swift`, `TailnetReader.swift`, `TailnetTCP.swift`, `TailnetActions.swift`, `MacStats.swift`, `DemoTailnet.swift`, `LauncherModel+Tailnet.swift`: the Tailnet view (`tailnet`, `/tailnet`). `TailscaleReader` runs the `tailscale` CLI with fixed arguments for the device list, this Mac's Serve shares, and pings, and `MacStats` reads this Mac's load from the kernel. `TailnetHTTP` asks devices only when Settings › General › Check tailnet devices is on, through `TailnetTCP` (Network.framework): only Tailscale addresses, no name lookups, no redirects, no proxy. App Transport Security blocks cleartext URL loads to Tailscale addresses, and it covers only URL loading. HTTPS connects to the address with the device's MagicDNS name as the TLS server name. `TailnetSource` (an `UpdatingSource`) shows what it knows at once, surveys the devices in the background, and calls `onUpdate` so `SourcePage` reloads; `SourcePage` also reloads every 5 seconds, and pages are checked again after 30. The view and the `tailnet` search share one source. `TailnetActions` holds the device actions (Remote Desktop, Screen Sharing, Taildrop, copy). `LauncherModel+Tailnet.swift` lists the pages the view found last in the main search, from preferences. `Tailnet/` in LauncherCore reads `tailscale status`, `serve status`, and `ping` output, the agent's report, plain HTTP answers (`PlainHTTP.swift`), and page titles and icons (`PageHead.swift`), and picks the ports to check. `scripts/tailnet-agent.ps1` is the read-only Windows agent; dot-source it to test its functions.

## Mail development

See [NATIVE_MAIL.md](NATIVE_MAIL.md) for account setup, provider registration, and
support limits. Native accounts use TLS IMAP and SMTP. Google and Microsoft use
public-client OAuth. App passwords and tokens are stored in the Keychain. The
account list and index are in `~/Library/Application Support/Jevcast/Mail`.
Local drafts and send history are in the separate owner-only `MailComposition`
folder. `MailDraftStore`, `MailModel+Persistence`, and `MailDeliveryView` implement
save and recovery. Recovery does not send. Uncertain delivery requires review.

For development without mail access, run `JEVCAST_MAIL_OFFLINE=1 swift test` and
`JEVCAST_MAIL_OFFLINE=1 scripts/build.sh`. Keep the same environment variable on
demo snapshot runs. Real transports, OAuth network requests, Mail Apple Events,
and Mail launch are blocked. Fake servers still work. Never run mail diagnostic
flags during an offline-only task.

Delete moves to a unique Trash folder. There is no purge action. Moves never use
mailbox-wide EXPUNGE. A refused sign-in stops background sync until the user
updates the sign-in. A queued action refuses a changed mail source.

Demo snapshots include `mail-workspace`, `mail-workspace-compact`, `mail-workspace-drafts`, `mail-workspace-search`, `mail-compose`, `mail-outbox`, and `mail-add-account`, and the Automations window at its normal size, at 980 points wide, and at its minimum size (`automations-*`).
They contain invented addresses and content, without account or credential reads.
AppleScript compilation and these renders are separate from live Mail proof.
Add `--mail-only` to `--snapshot-ui <dir> --demo` to render only the ten Mail
fixtures. This path does not start a launcher session or read desktop context.
`mail-draft-signin-blocked` and `mail-draft-review-blocked` show the draft recovery
row with invented failures. After fixing a refused sign-in, choose Save to Drafts
Again to retry that draft's server save. This action does not send. Uncertain or
unclassified server changes stay blocked and require review.

The Mail window has an account and folder sidebar, favourites, and unified Inbox,
All Mail, Unread, Flagged, Drafts, Sent, and Outbox views. All Mail and Unread cover
non-Trash/non-Junk folders and remove duplicate message copies. Native accounts
retain every selectable server folder. Opening a folder syncs its newest headers;
older headers load in bounded batches as the list reaches the end.

Native local search uses an FTS index of downloaded headers and body text. Search
scope can cover the current view or all accounts. Search Server is explicit and
uses bounded UID ranges. Servers that hide older history report incomplete
results. Server search hits do not advance normal history coverage.

Server drafts need a unique Drafts mapping and UIDPLUS. Each owned copy records
its exact account, folder, UIDVALIDITY, UID, Message-ID, and content digest.
Autosave replaces a copy only after verifying its identity. Ambiguous changes
require review. SMTP acceptance and Sent filing have separate durable states.
Repair Sent Copy uses IMAP only and never sends the message again. Interrupted
sends never resume at startup. Received attachments load only on an explicit
Preview, Open, Save, or Forward action.

## Calendar

Calendar opens in Week with a scrollable hourly grid. Day uses the same grid;
Month and List remain available. Click an event to read its description, meeting
notes, location, organizer, guests, and attachments. Join Google Meet opens the
event's meeting link in the system browser. Notes come from the event description.
Linked documents open in the browser. Jevcast does not record meetings or generate notes.

Connect Google in the Calendar header starts a separate read-only Google sign-in.
The sign-in window stays open while the system browser is active. Once connected,
reopen Calendar to see Google events. Closing the sign-in window cancels the request.
Use a Google OAuth client with type Desktop app, enable the Google Calendar API,
and add `https://www.googleapis.com/auth/calendar.readonly` to the consent screen.
While the Google app is in Testing, add the signing-in address as a test user.
The Desktop client configured for Mail can be reused. Calendar keeps its client
ID and token separately; it never uses the Mail access token. Tokens and desktop
client secrets stay in the Keychain. In Google's Testing mode, refresh tokens
for this scope can expire after seven days; sign in again when requested.

The source menu switches between Google and On This Mac. Google needs no macOS
Calendar permission. Calendars chooses which Google calendars to show. Refresh
reloads the calendar list and current date range. Disconnect removes only the
local Calendar token and selection, then returns to On This Mac. It does not
delete Google events or revoke access for Mail.

Google calls are GET requests to the fixed Calendar API. OAuth uses the shared
PKCE and loopback callback code. API and token requests refuse redirects. Event
descriptions render as text, and attachments open only when clicked. API checks
inject fake HTTP responses and account checks inject in-memory credentials.
`JEVCAST_CALENDAR_OFFLINE=1` blocks live Calendar traffic and sign-in.
`JEVCAST_MAIL_OFFLINE=1` and snapshot mode also block it.

`--snapshot-ui <dir> --demo --calendar-only` renders Week, Day, Month, event
details, a compact Week, and the Google sign-in form with invented events and
fresh preferences. It does not read EventKit or Keychain credentials.

## Rename the app

Change `AppIdentity.swift` and the `APP_NAME` and `BUNDLE_ID` lines in `scripts/build.sh`. `AppIdentityTests` fails if the two disagree. Then search for the old name in `Sources`, `site`, and the documents. A new bundle ID starts with empty preferences and a new Keychain item.

## Diagnostic flags

Run the executable inside the app bundle, for example `"dist/Jevcast.app/Contents/MacOS/JevLauncher" --diagnose`.

| Flag                                       | Result                                                                                                                                                                                                                                                                                |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--diagnose`                               | Prints catalogue size, first results for sample queries, and search timings. Opens nothing.                                                                                                                                                                                           |
| `--diagnose-files 'kind:pdf in:downloads'` | Prints file-search results from your folders for five seconds.                                                                                                                                                                                                                        |
| `--diagnose-source 'scheduled tasks'`      | Prints the rows and verbs a source query lists. Runs nothing. Tabs may ask for Automation access.                                                                                                                                                                                     |
| `--diagnose-mail`                          | Checks that Apple Mail can be read. Prints column names, counts per mailbox kind, inbox and All Mail totals, whether Mail runs, and page and search timings. Never subjects or addresses.                                                                                             |
| `--diagnose-native-mail`                   | For each Jevcast mail account, signs in to IMAP and SMTP with the saved password and prints capabilities, mailbox roles and counts, and timings. Changes nothing. Never mailbox names, subjects, or addresses. |
| `--diagnose-mail-setup`                    | Checks local OAuth client IDs and whether the signed app can read its Google desktop secret. No network requests, mailbox access, or Apple Events. Never prints credentials. |
| `--diagnose-jev 'request' …`               | Runs each request through the launcher with the stored TypeSafe key and prints the pick, the top row, and the tokens used. Billed, and counted in Settings › AI › Usage.                                                                                                              |
| `echo KEY \| … --store-jev-key`            | Saves a TypeSafe or OpenRouter key in the Keychain from standard input, as Settings › AI › Jev does. The key is never an argument or printed.                                                                                                                                         |
| `--hyper-led-test`                         | Turns the Caps Lock light on for two seconds, then off. Prints whether each step worked and quits. Changes no key mapping.                                                                                                                                                            |
| `--open`                                   | Shows the launcher at launch.                                                                                                                                                                                                                                                         |
| `--terminal`                               | Opens the Terminal view (Hyper–T) at launch.                                                                                                                                                                                                                                          |
| `--turn-on-runner`                         | Registers the background runner at launch, as Settings › Automations › Turn On does.                                                                                                                                                                                                  |
| `--automation-alerts`                      | Starts without the welcome window or the launcher and shows pending automation alerts. The runner uses it. When a copy already runs, it is not brought to the front.                                                                                                                  |
| `--notch-demo`                             | Runs the notch panel alone with invented alerts on a fixed timeline (one running, three running at 30 s, a review at 60 s, a question at 80 s), then quits after 120 s. It does not start while Jevcast runs, because both would use the notch. It builds no launcher, menu, preferences, stores, or hotkeys; buttons only print. |
| `--welcome`                                | Shows the welcome window at launch.                                                                                                                                                                                                                                                   |
| `--trace-latency`                          | Prints panel and result timings. No query text.                                                                                                                                                                                                                                       |
| `--trace-interaction`                      | Prints open, close, focus, and resize events. No query text.                                                                                                                                                                                                                          |
| `--snapshot-ui <dir>`                      | Renders the launcher states, each panel view, each Settings pane, and the welcome window to PNG files, then quits. It adds no menu-bar item, so only the running copy shows one. Automations use a temporary empty store; the real Automations folder, the runner, and the CLIs are never touched. Mail, Calendar, and Clean Up views render empty. |
| `--snapshot-ui <dir> --demo`               | The same, with invented sample files, Apple apps only, and fresh settings. Use this for public images.                                                                                                                                                                                |

Snapshot runs keep clipboard history in memory with invented entries drawn in code (`DemoClipboard.swift`), so they never read or change the stored history. `view-clipboard-image` and `view-clipboard-code` show the view with an image and with code selected.

Snapshots render the app's own views. They show layout only, not window material, shadows, or the toolbar. Snapshot windows stay transparent and never take focus, clicks, or typing.

`scripts/window-fixture.sh` opens two disposable windows for window-action checks. Avoid Tile All and Cascade All during these checks, because they move every eligible window on the display.

## Icon

`swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns` and the Icon Composer bundle `Resources/AppIcon.icon`. `scripts/build.sh` compiles the bundle with `xcrun actool`, so macOS 26 shows a Liquid Glass icon. Without actool it ships the `.icns`.

## Build notes

- The Terminal links libghostty as `Vendor/GhosttyKit.xcframework` (not in git). `scripts/ghosttykit.sh` builds it from the Ghostty release pinned in the script, with Homebrew `zig@0.15` and Xcode's Metal Toolchain, and `scripts/build.sh` runs it first. It does nothing when the build matches the pinned commit, the script, and `scripts/ghosttykit-libtool.patch`. The patch is Ghostty's own fix (be9f1562, after 1.3.1): newer `libtool` drops unaligned members of Zig's archives with only a warning, so the script also checks that the library exports `ghostty_surface_new`. Sentry and gettext are off. `scripts/build.sh` copies Ghostty's license to `Contents/Resources/Licenses`.
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
