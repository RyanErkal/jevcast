# Local Preview Verification

Date: 2026-09-22
Version: 0.2.0 (2)

## Completed

- `swift test`: 50 tests passed, zero failures. This includes the existing 132 command text cases.
- Reproduced two selection failures before fixing them: duplicate speech reset the selected row, and late speech replaced typed input. Both regression tests now pass.
- File tests cover query parsing, kind/date predicates, folder containment, path traversal and symlink containment, disabled stale results, and rejected late callbacks.
- Live Spotlight testing found a crash caused by an AND predicate with one child. The corrected single-word query completed successfully.
- `scripts/build.sh`: release app built and ad-hoc signature verified. Installed and built executable hashes match.
- Live native UI checks: filename/type/folder/date results, paths containing spaces, arrow-key selection, Command–K actions, and Enter opening the selected result.
- Enter launched Calculator. Enter on a disposable text file opened that exact file in TextEdit; its title, URL, and contents were verified through Accessibility.
- Quick Look was invoked from the action menu, and Escape returned to search. Its separate preview content was not captured for visual verification.
- Native results and selection were inspected in screenshots. Rows now expose separate accessibility elements.

## Timing Samples

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

The previous app is recoverable at:
`~/Library/Application Support/JevLauncher/Backups/20260922-065258/Jev Launcher.app`
