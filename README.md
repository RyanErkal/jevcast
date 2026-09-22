# Jev Launcher

A native macOS launcher and window manager. SwiftUI and AppKit, macOS 14 or later. No third-party runtime dependencies.

## Build and open

```sh
swift test
./scripts/build.sh
open "dist/Jev Launcher.app"
```

The initial shortcut is **Control–Shift–Space**. Change it in Settings. Existing Spotlight, Raycast, and Rectangle shortcuts are not changed. Open Settings from the menu-bar icon or Command–Comma in the launcher.

## Core use

- Type an app name or alias, a filename, a URL, a calculation, or a window action.
- Return runs the selected result. Arrow keys select another result. Escape closes the panel.
- Command–K opens actions for the selected result. Command–Y toggles Quick Look. Command–R reveals a file/app in Finder. Command–Shift–C copies its path.
- Right-click an app to add a favourite. Set app aliases and additional app/search folders in Settings.
- App names and built-in commands rank locally. Files use Spotlight for filename, kind, folder, and modified-date search. Exact local commands and explicit file searches do not call Jev.
- Examples: `Safari`, `left half`, `top right`, `middle third`, `next monitor`, `full screen`, `tile all`, `12 * (8 + 2)`.

## File search

- `find file invoice` searches file names.
- `kind:pdf in:downloads` shows PDFs in Downloads.
- `pdfs in downloads` uses the same local filters.
- `find folder invoices` searches folders.
- `files modified today` filters by modification date.
- `kind:image modified:yesterday` finds images modified yesterday.
- `modified:week` means the current calendar week.
- `in:"~/Documents/My Folder" report` narrows a filename search.
- An absolute path or `~/` path opens an existing file or folder, even if Spotlight has not indexed it.

Search stays within the folders configured in Settings. The list omits app bundles, Git internals, dependency folders, caches, and Trash. Broad searches show a bounded set of results. Add a name or folder filter to narrow them. Document contents are not searched.

The first result is selected when a new query returns. Arrow-key selection remains fixed during updates when that result still exists. While a file query updates, previous results stay visible but dimmed and disabled. Return cannot open a file from the previous search.

## Voice

Enable Microphone and Speech access from Settings once. Thereafter the panel starts listening on open by default. Typing, Return, Escape, or closing the panel stops capture. The system input microphone is used. Audio is not saved.

This build requires on-device Apple speech recognition. If the current language or device does not support it, the app displays a status and typed input remains available. It does not silently send audio to a cloud service.

## Window control

Grant Accessibility access from Settings. The app records the active application before showing the launcher, then captures its focused window. Native full screen and maximise are separate actions. Window movement is limited by the target app's resize support and minimum size.

Optional direct shortcuts use Control–Option–Command:

| Keys | Action |
| --- | --- |
| Left / Right / Up / Down | Halves |
| U / I / J / K | Top left / top right / bottom left / bottom right |
| 1 / 2 / 3 | Left / middle / right thirds |
| Return | Maximise |
| Z | Restore |
| N / P | Next / previous display |

Edge snapping is a separate preference. Leave Rectangle's snapping disabled when testing this app's snapping to avoid two apps moving the same window.

## Jev

Add your own TypeSafe API key in Settings and enable Jev. The key is stored in macOS Keychain. No key is embedded in the binary.

For ambiguous general requests, Jev receives request text and a bounded list of candidate names/descriptions, which can include file paths. Explicit file requests stay local. It returns a known action ID or no match. It cannot generate or execute shell commands. Local results do not wait for the network. Closing the panel or changing the query invalidates old replies.

## Development boundaries

The app is built for direct distribution. The build script uses an ad-hoc signature by default. Set `SIGNING_IDENTITY` to a suitable Developer ID identity for signing. Ad-hoc signing is suitable for a local preview; it is not Apple notarization. Rebuilding an ad-hoc app can require renewed privacy permissions.

Custom actions, custom scripts, and content-based document search are outside this initial build. Runtime permissions, microphone hardware, Spaces, and target-app behaviour require real Mac checks in addition to unit tests.

## Read-only and isolated diagnostics

```sh
"dist/Jev Launcher.app/Contents/MacOS/JevLauncher" --diagnose
./scripts/window-fixture.sh
```

The diagnostic prints catalogue size, representative first results, and release-search timings. It does not open apps or alter windows. The fixture opens two disposable windows for manual window-control checks. Close both fixture windows when done. Avoid Tile All/Cascade All during isolated checks because those actions intentionally affect other eligible windows on the display.

For a local file-search check, use `--diagnose-files 'kind:pdf in:downloads'`. This prints filenames from the selected scope for five seconds. Use `--trace-latency` when running the app executable to print panel, local-result, and table-update timings. These timings exclude display compositor latency and spoken-input accuracy. No query text is included in latency output.
