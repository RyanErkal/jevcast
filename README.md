# Jev Launcher

A native macOS launcher and window manager. SwiftUI and AppKit, macOS 14 or later. No third-party runtime dependencies.

## Build and open

```sh
swift test
./scripts/build.sh
open "dist/Jev Launcher.app"
```

The initial shortcut is **Control–Shift–Space**. Change it in Settings. Existing Spotlight, Raycast, and Rectangle shortcuts are not changed. The app lives in the menu bar and shows nothing at launch; open it with the shortcut or from the menu-bar icon. Open Settings from the menu-bar icon or Command–Comma.

## Core use

- Type an app name or alias, a filename, a URL, a calculation, or a window action.
- Opening focuses search in a non-activating key panel, so typing works even when macOS declines to activate the app. Return runs the selected result. Arrow keys select another result. Escape closes the entire launcher, including its actions menu and preview.
- With an empty query, the panel shows only favourites and recent picks. If there are none, it shows only the search bar. Results are grouped as Applications, Commands, Files, and Clipboard, with the top hit's group first. Mixed searches show at most three files. The footer names the Return action for the selected result. Errors and file-search status share one strip above the footer.
- An outside click closes Jev and is consumed. Background clicks and scrolling are blocked while it is open. Switching apps dismisses it. Cancellation restores the previous app.
- The menu-bar menu shows Open/Hide with the current shortcut, a Listen When Opened toggle, a Permissions submenu with live ticks that open the matching System Settings pane, Settings, About, and Quit.
- Settings uses four toolbar tabs: General (shortcut, login, clipboard history, web engine), Search (file folders, app aliases, search keywords, and app folders under Advanced), Windows (Accessibility, shortcuts, snapping, gap), and Input (voice input, Microphone and Speech permissions, API key, natural language). About Jev Launcher in the menu shows the standard About panel with the version.
- Command–K opens actions for the selected result. Command–Y toggles Quick Look. Command–R reveals a file/app in Finder. Command–Shift–C copies its path.
- Right-click an app to add a favourite. Set app aliases and file folders in Settings › Search. Additional app folders are under Advanced.
- App names and built-in commands rank locally. Files use Spotlight for filename, kind, folder, and modified-date search. Exact local commands and explicit file searches do not call Jev.
- Examples: `Safari`, `left half`, `top right`, `middle third`, `almost maximise`, `next monitor`, `full screen`, `tile all`, `12 * (8 + 2)`, `100 + 10%`, `10 km in mi`, `wi-fi settings`.
- A number alone does not show a calculator result. Unit conversion covers length, mass, temperature, time, data, volume, speed, and area. Currency is not supported.
- Ranking learns from use. Frequent and recent picks rank higher, with decay over time. A short query learns the result you picked for it.
- Search keywords: `gh query`, `yt query`, `maps query`, and `wiki query` open a search. A keyword alone opens the site. Add or edit keywords in Settings › Search. Click a keyword to edit it.
- Clipboard history: type `clip` or `clipboard`, then Return copies the entry again. Only plain text is kept, in memory, up to 50 items. Password-manager and concealed items are skipped. Turn it off in Settings › General.

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

Enable Microphone and Speech access from Settings › Input once. The mic button appears in the launcher only after both are allowed. Thereafter the panel starts listening on open by default. Typing, Return, Escape, or closing the panel stops capture. The system input microphone is used. Audio is not saved.

This build requires on-device Apple speech recognition. If the current language or device does not support it, the app displays a status and typed input remains available. It does not silently send audio to a cloud service.

## Window control

Grant Accessibility access from Settings › Windows. The app records the active application before showing the launcher, then captures its focused window. Native full screen and maximise are separate actions. Window movement is limited by the target app's resize support and minimum size.

Optional direct shortcuts use Control–Option–Command:

| Keys                     | Action                                            |
| ------------------------ | ------------------------------------------------- |
| Left / Right / Up / Down | Halves                                            |
| U / I / J / K            | Top left / top right / bottom left / bottom right |
| 1 / 2 / 3                | Left / middle / right thirds                      |
| Return                   | Maximise                                          |
| Z                        | Restore                                           |
| N / P                    | Next / previous display                           |

Press a half or the centre third again to cycle its size. The current frame sets the next size. Halves (left, right, top, bottom) go 1/2, 2/3, then 1/3. Centre third (middle third) goes 1/3, 1/2, then 2/3.

Edge snapping is a separate preference. It snaps only at outer screen edges, not at an edge shared with another display. Leave Rectangle's snapping and the macOS window tiling option ("Drag windows to screen edges to tile") disabled when testing this app's snapping, to avoid two apps moving the same window.

## Jev

Add your own TypeSafe API key in Settings › Input, then turn on natural-language matching. The toggle stays off until a key is stored. The key is stored in macOS Keychain. No key is embedded in the binary.

For ambiguous general requests, Jev receives request text and a bounded list of candidate names and short descriptions. Candidate IDs are opaque. File candidates are sent as names only, never as paths or folders. Queries shorter than three characters do not start a background file search. Explicit file requests stay local. It returns a known action ID or no match. It cannot generate or execute shell commands. Local results do not wait for the network. Closing the panel or changing the query invalidates old replies.

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

`--open` shows the panel at launch. `--trace-interaction` prints open, close, focus, resize, and typed-length events without query text. `--snapshot-ui <dir>` renders the launcher states and each Settings pane to PNG from the app's own views and quits; it captures layout only, not window material or the toolbar. Snapshot windows stay transparent and never take focus, clicks, or typing. `swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns` and the Icon Composer bundle `Resources/AppIcon.icon`. The build script compiles the bundle with `xcrun actool` (Xcode required) so macOS 26 shows a Liquid Glass icon; without actool it ships the `.icns`.
