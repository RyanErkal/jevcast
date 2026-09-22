# Local Preview Verification

Date: 2026-09-22
Version: 0.2.1 (3)

## Focus and Dismissal Update

- The launcher now explicitly activates the app and assigns the native search field as first responder. The panel no longer uses the non-activating style.
- Native UI check: typed `left half` without clicking the field; the query and ranked results updated. Runtime tracing confirmed the app was active, the launcher was key, and its field editor owned input.
- Escape closed the launcher. A separate check opened Command–K and confirmed one Escape closed both the menu and launcher.
- A click 20 points outside the observed launcher edge closed the session through the click-catching layer. The layer consumes down/up events and scroll events across attached displays.
- Cancellation restores the previous app. Execution lets the chosen app/file take focus; copy and active-window actions restore prior focus. A read-only frontmost-app check confirmed T3 Code was active after cancellation.
- `swift test`: all 50 existing tests passed. Release build and signature verification passed.
- Physical global-hotkey input remains a manual check. The automation tool inserted Option–Space as a nonbreaking space into the disposable fixture, so that attempt did not prove global-hotkey delivery. Repeated opening via the app surface and typing were verified.
- Multi-display click interception, a click on a specific background control, and fullscreen Spaces were not independently verified. No permission settings were changed.

## Completed

- `swift test`: 50 tests passed, zero failures. This includes the existing 132 command text cases.
- Reproduced two selection failures before fixing them: duplicate speech reset the selected row, and late speech replaced typed input. Both regression tests now pass.
- File tests cover query parsing, kind/date predicates, folder containment, path traversal and symlink containment, disabled stale results, and rejected late callbacks.
- Live Spotlight testing found a crash caused by an AND predicate with one child. The corrected single-word query completed successfully.
- `scripts/build.sh`: release app built and ad-hoc signature verified. Installed and built executable hashes match.
- Live native UI checks: filename/type/folder/date results, paths containing spaces, arrow-key selection, Command–K actions, and Enter opening the selected result.
- Enter launched Calculator. Enter on a disposable text file opened that exact file in TextEdit; its title, URL, and contents were verified through Accessibility.
- Quick Look was invoked from the action menu in 0.2.0. Its separate preview content was not captured for visual verification.
- Native results and selection were inspected in screenshots. Rows now expose separate accessibility elements.

## Timing Samples

These samples were recorded on 0.2.0 before the focus update.

- The installed release recorded panel preparation/display calls of 118.60 ms on its first opening and 26.52–27.79 ms on two later openings.
- Local result rebuilding in that sample took 4.45–7.83 ms; table updates took 0.01–3.21 ms.
- Release Spotlight checks returned the disposable document/folder matches in 94–95 ms. A direct path returned in 12 ms. The launcher adds a 120 ms typing debounce before file queries.
- These are small local samples, not percentile guarantees. Panel timing excludes compositor completion and microphone startup. Voice permissions were unavailable in this build during timing.

## Remaining Device Checks

- This rebuilt ad-hoc app shows Enable Voice. Microphone and Speech access need to be enabled again before real spoken-input and audio-device checks. Permission settings were not changed by automation.
- Accessibility access was absent before the update. Actual window movement, edge snapping, restore, multiple displays, and Spaces remain unverified.
- Quick Look rendering for different file formats and preview keyboard behavior need a manual visual check.
- Live Jev calls, launch at login, and Apple notarization were not exercised. API tests use mocked responses.

## Installed App

`~/Applications/Jev Launcher.app`

The existing Option–Space shortcut and preferences were retained. No saved actions, project commands, or scripts were added. File content search is not included. Spotlight searches inspect at most 640 metadata candidates and show up to 40 results; broad searches advise narrowing the query.

The previous 0.2.0 app is recoverable at:
`~/Library/Application Support/JevLauncher/Backups/20260922-070742/Jev Launcher.app`
