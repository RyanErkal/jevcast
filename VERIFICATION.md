# Local Preview Verification

Date: 2026-09-21

## Completed

- `swift test`: 31 tests passed, zero failures.
- The command acceptance test contains 132 typed/spoken text cases. These test text interpretation, not microphone recognition.
- Tests cover local search, calculator parsing, hidden app links (including the Safari discovery issue), window geometry, unsorted displays, stale launcher transcripts, manual selection, and mocked TypeSafe API responses.
- `scripts/build.sh`: release app built; local ad-hoc signature verified.
- Read-only release diagnostic: standard app discovery works, including Safari and Finder. Representative window commands rank first.
- A local release diagnostic measured roughly 1.6 ms p95 for catalogue/action ranking. This excludes panel rendering, transcription, network calls, and action execution.

## Not Yet Verified

- Native visual/keyboard QA. Computer Use returned `cgWindowNotFound` for this app and for existing Finder/Chrome windows, so no screenshots or UI assertions were available.
- Accessibility permission and actual window movement, edge snapping, bulk arrangement, undo, Spaces, and multiple physical displays.
- Microphone and Speech permissions, real spoken input, on-device language availability, and speech latency.
- Live Jev requests. API tests used mocked responses. Add a personal TypeSafe key in Settings to enable Jev.
- Launch-at-login operation.
- Apple notarization. This is a local preview with an ad-hoc signature, not a notarized public release.

## Installed App

`~/Applications/Jev Launcher.app`

Default shortcut: Control–Shift–Space. Voice starts on open after the required permissions are granted. Window control requires Accessibility access. Existing launcher/window-manager settings were not changed.
