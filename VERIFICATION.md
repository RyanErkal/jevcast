# Local Preview Verification

Date: 2026-09-22
Version: 0.3.0 (4)

## Settings Redesign Update

Changes:

- Four toolbar tabs: General, Search, Windows, Input. Voice and Jev are merged into Input (Voice input, Permissions, API key, Natural language). The About section and the "Last local search" and "Model" rows are removed. The menu-bar About item activates the app and shows the standard About panel.
- Search: file folders first. App aliases and search keywords are added in sheets. Click a keyword row to edit it. Keyword rows show `keyword · Name · host`. Additional app folders and the app count are in a collapsed Advanced group.
- The natural-language toggle stays off and disabled until a key is stored. The idle speech status is removed.
- Copy: British spelling (Maximise, Centre, Behaviour), sentence-case headers, "Permissions" everywhere. Window action titles changed; American spellings stay as aliases. Raw values did not change.

Proof:

- `swift test`: 78 tests, all pass (rechecked 2026-09-22 before the checkpoint commit). The two `LauncherFlowTests` lookups now use the new title `"Maximise"`.
- `scripts/build.sh`: release build and ad-hoc signature verified.
- `--snapshot-ui`: the four Settings panes rendered and were checked. Temporary local renders also checked the expanded Advanced group, the stored-key state, and the keyword and alias sheets.

Not verified: sheets as real sheets, the toolbar tab icons, pane-height animation, the About panel, and Keychain save/remove on a real key.

## UI Refinement Update

Code and build proof:

- `swift test`: 50 tests passed (26 LauncherCore, 24 JevLauncher), zero failures. One pre-existing timing race in `testCancellationIsPropagatedBeforeRequest` was removed by mapping `URLError.cancelled` to `CancellationError` in `JevService`.
- `scripts/build.sh`: release build, `AppIcon.icns` bundled, ad-hoc signature verified. Installed and built executable hashes match.
- Layout was checked from rendered PNGs of the app's own views (`--snapshot-ui`): launcher empty, app query, file query, error strip, and all five Settings panes. These captures show layout only, not window material, shadow, or the Settings toolbar.
- Window-server checks with the installed app running: the panel frame followed content (680x137 empty, 680x598 with seven rows), and after a normal launch no launcher window and no backdrop window were on screen.

Changes:

- Launcher: borderless non-activating key panel with popover material, continuous 14 pt corners, and a hairline border. The panel resizes to its content up to seven rows. Real app and file icons, accent-coloured inset selection with a Return hint, one status strip for errors, permission prompts, and file status, key-cap hints in the footer. The gear button was removed; Settings is on the menu bar and Command–Comma.
- The panel no longer opens automatically at launch. `--open` restores that for diagnostics.
- Dismissal: a Workspace app-switch observer hides the launcher when another app activates, in addition to the existing deactivation, outside-click, Escape, and display-change paths.
- Main menu with Edit and Window menus, so Command–Comma, Command–Q, Command–W, and paste work in every window.
- Menu bar: template sparkle icon; menu rebuilt on open with Open/Hide, the shortcut, Listen When Opened, a Permissions submenu with live ticks, Settings, About, and Quit.
- Settings: preference-style toolbar tabs (General, Search, Voice, Window, Jev), bordered folder lists with +/− controls, an alias table, permission rows with live status, a shortcut reference grid, labelled gap slider, Keychain key status, and the bundle version. No preference keys changed; the Keychain key and Option–Space selection are retained.
- App icon, `NSApplicationSupportsSecureRestorableState`, and copyright added to the bundle.

## Not Verified On This Mac

During this session the screen was locked and both displays were asleep (`CGSSessionScreenIsLocked` set; the app saw `loginwindow` as frontmost). Traces from the installed app showed the launcher and backdrops on screen but `active=false key=false`, which is expected under a lock and does not prove or disprove hotkey activation. The non-activating panel was adopted so typing does not depend on macOS granting activation, but the following remain unverified until someone is at the Mac:

1. Search focus without a click after a physical Option–Space press.
2. Retention of the first typed characters.
3. Escape dismissing launcher, actions menu, and preview.
4. Outside click dismissing without activating a control underneath, including on a second display and in fullscreen Spaces.
5. Background apps receiving no typing, clicks, or scrolling while open.
6. Cancellation restoring the previous app.
7. App and file execution keeping focus on the destination.
8. Backdrop removal after close, app switch, errors, and display changes (the display-change and close paths were exercised only by code inspection and the window-server check above).

Also unverified: menu-bar icon rendering in light and dark menu bars, Settings toolbar appearance and pane-height animation, Quick Look rendering, real transcription (Microphone and Speech permissions must be granted again for this ad-hoc rebuild), real window movement, live Jev requests, launch at login, and notarization.

## Installed App

`~/Applications/Jev Launcher.app`, running with its panel closed.

Backups:

- 0.2.1: `~/Library/Application Support/JevLauncher/Backups/20260922-074022/Jev Launcher.app`
- 0.2.0: `~/Library/Application Support/JevLauncher/Backups/20260922-070742/Jev Launcher.app`
