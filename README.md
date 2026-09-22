# Jevcast

A keyboard launcher and window manager for macOS. Open apps, find files, do quick sums and conversions, move windows, and reuse what you copied, all from one shortcut. Free and open source under the MIT License.

![The launcher showing Safari, two files, and a web search for the query "saf"](site/images/launcher-query.png)

- Native SwiftUI and AppKit app. No third-party code.
- macOS 14 or later. Apple silicon and Intel.
- No account, no analytics. Search, clipboard history, and voice stay on your Mac.

Website: [jevcast.vercel.app](https://jevcast.vercel.app).

## Install

**Agent install prompt:**

```
Install Jevcast from the official source repository:
https://github.com/RyanErkal/jevcast

First check that this Mac can run Xcode 26 or later and has it installed. If
not, report the requirement and stop. Clone the repository and check out its
latest published release tag. If there is no release tag, stop. Verify that `git remote get-url origin`
resolves exactly to `https://github.com/RyanErkal/jevcast.git`. Run `swift test`
and `scripts/build.sh`. Verify the built app code signature with
`codesign --verify --deep --strict --verbose=2 "dist/Jevcast.app"` and report
the result. After those checks pass, quit any running Jev Launcher or Jevcast.
Back up an existing `/Applications/Jevcast.app` before replacing it, and keep
all preferences and settings. Install the new app at `/Applications/Jevcast.app`
and open it. Do not bypass Gatekeeper or change macOS security settings.
```

Open the app from Applications. A welcome window helps you choose a shortcut and allow what you need. After that, the app lives in the menu bar. Open **Help › Welcome Guide** to see the window again.

## Use

Press **Option–Space** and type. If another app already uses that shortcut, choose a different one in the welcome window or in Settings.

| Type                                                       | What happens                                                             |
| ---------------------------------------------------------- | ------------------------------------------------------------------------ |
| `safari`                                                   | Opens Safari. Aliases you add in Settings › Search also work.            |
| `left half`, `top right`, `middle third`, `next monitor`   | Moves the window you were using.                                         |
| `12 * (8 + 2)`, `100 + 10%`                                | Shows the answer. Return copies it.                                      |
| `10 km in mi`, `20 c in f`                                 | Converts length, mass, temperature, time, data, volume, speed, and area. |
| `invoice`, `kind:pdf in:downloads`, `files modified today` | Finds files by name, kind, folder, and date.                             |
| `gh swiftui`, `yt piano`, `maps cafes`, `wiki moon`        | Searches a site. Add your own keywords in Settings › Search.             |
| `clip`                                                     | Shows the last 50 text items you copied. Return copies one again.        |
| `wi-fi settings`                                           | Opens that System Settings pane.                                         |

Keys in the launcher:

| Keys            | Action                               |
| --------------- | ------------------------------------ |
| Return          | Run the selected result              |
| Up, Down        | Select another result                |
| Escape          | Close                                |
| Command–K       | More actions for the selected result |
| Command–Y       | Quick Look                           |
| Command–R       | Show in Finder                       |
| Command–Shift–C | Copy the path                        |

Results learn from use. Things you pick often and recently move up. Right-click an app to add it to your favourites. With nothing typed, the launcher shows your favourites and recent picks.

### File search

- `find file invoice` searches file names. `find folder invoices` searches folders.
- `kind:pdf in:downloads` and `pdfs in downloads` show PDFs in Downloads.
- `kind:image modified:yesterday`, `files modified today`, and `modified:week` filter by date.
- `in:"~/Documents/My Folder" report` searches one folder.
- A full path or a `~/` path opens that file or folder.

File search uses the Spotlight index and stays inside the folders in Settings › Search. It skips app bundles, Git folders, dependency folders, caches, and the Trash. It does not search inside documents.

### Window shortcuts

Allow Accessibility access, then turn on **Use direct window shortcuts** in Settings › Windows. Hold **Control–Option–Command** and press:

| Key                   | Action                                                  |
| --------------------- | ------------------------------------------------------- |
| Left, Right, Up, Down | Halves                                                  |
| U, I, J, K            | Top left, top right, bottom left, bottom right quarters |
| 1, 2, 3               | Left, middle, right thirds                              |
| Return                | Maximise                                                |
| Z                     | Restore                                                 |
| N, P                  | Next or previous display                                |

Press a half again to cycle its size: 1/2, 2/3, then 1/3. The middle third cycles 1/3, 1/2, then 2/3. Edge snapping is a separate setting. If you use Rectangle or the macOS option "Drag windows to screen edges to tile", turn off one of them, so two apps do not move the same window.

### Voice

Turn on **Listen when the launcher opens** in Settings › Input and allow Microphone and Speech Recognition. The launcher then listens each time it opens. Typing stops listening. Recognition runs on your Mac only, and audio is not saved. If on-device recognition is not available for your language, the app tells you and typing still works.

### Natural language (optional)

Jev, a model from [TypeSafe](https://typesafe.ai), can match loose requests such as "make this window bigger" to a known action. Add your own TypeSafe API key in Settings › Input, then turn on natural-language matching. The key is kept in your macOS Keychain. Local results never wait for Jev.

## Privacy

The app has no account, no analytics, and no crash reporting. It connects to the internet for three things only:

| When                                                                             | Where                                | What is sent                                                                                                                                                                                                          |
| -------------------------------------------------------------------------------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Once a day, if **Check for updates automatically** is on (default: on)           | `api.github.com`                     | A request for the newest release, with the app version. GitHub sees your IP address, as with any web request. Nothing is downloaded.                                                                                  |
| When you type a loose request, if natural-language matching is on (default: off) | `api.typesafe.ai`, with your own key | The text you typed and a short list of candidate names: apps, window actions, search sites, and file names. Never file paths, folders, or audio. Jev can only choose one of those candidates. It cannot run commands. |
| When you open a web search or a URL                                              | Your default browser                 | Whatever you chose to open.                                                                                                                                                                                           |

Everything else stays on your Mac. Clipboard history is kept in memory only, holds plain text only, and skips items that password managers mark as concealed. The app writes one file of its own: a cache of your app list in `~/Library/Caches/JevLauncher`.

## Permissions

| Permission                        | Needed for                  | Required?               |
| --------------------------------- | --------------------------- | ----------------------- |
| Accessibility                     | Moving and resizing windows | Only for window actions |
| Microphone and Speech Recognition | Voice input                 | Only for voice          |

Allow each one from the welcome window, Settings, or the **Permissions** menu in the menu bar. Each item opens the matching page of System Settings.

## Build from source

You need Xcode 26 or later (it includes the macOS 26 SDK). The built app runs on macOS 14 or later.

```sh
git clone https://github.com/RyanErkal/jevcast.git
cd jevcast
swift test
scripts/build.sh            # universal build; ARCHS=arm64 scripts/build.sh builds one architecture
open "dist/Jevcast.app"
```

A local build can ask for permissions again after each rebuild. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the code layout and diagnostic flags, and [docs/RELEASING.md](docs/RELEASING.md) for the source release process.

## Contributing

Bug reports and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE) © 2026 Ryan Erkal
