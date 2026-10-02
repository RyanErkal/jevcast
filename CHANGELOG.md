# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org).

## [1.16.1] - 2026-10-03

### Added

- **Computer-use cleanup.** Clean Up lists known computer-use workers with their PID, program, and parent. Attached workers and the shared service stay locked. Orphaned workers start unchecked; the group stop asks for a second Return. Jevcast checks ownership and process identity again before stopping, and reports any processes that remain.

### Fixed

- **Settings search.** `settings` puts the System Settings app first. A pane appears only for a named request such as `bluetooth settings` or `focus settings`, and only matching panes appear.
- **App matching and launch.** Compact names such as `t3code` rank with spaced names. Favourites and past use cannot lift a partial match above an exact name. Jevcast activates the app instance returned by macOS, checks its location, and records use only after a successful launch. A failed launch shows its reason.
- **Late search answers.** Saved and cached picks obey hidden-app and settings-pane rules. A delayed Jev or saved answer cannot replace a clear local answer or the row you select.
- **Typing and Return.** Search keeps input-method composition intact and stops pending matching until the text is committed. Holding Return cannot confirm an action a second time. A late app launch cannot close or block a new search, or replace its newer learned choice.
- Clean Up keeps coding CLIs, IPC workers, regular apps, and protected child trees running. Changed or reused process IDs cannot be stopped from an old checklist.

### Changed

- Search prepares app names once and reuses them while you type. Requests with unrelated extra words receive a weaker match.

## [1.16.0] - 2026-10-02

### Added

- **Google and Microsoft sign-in for mail accounts.** Gmail can use Google Sign-In and Outlook Microsoft sign-in, with your own free OAuth client. Jevcast ships with none. The steps are in `docs/NATIVE_MAIL.md`. Sign-in uses PKCE, a loopback callback, and the Keychain.
- **An Apple Mail style composer.** Replies, forwards, and new messages open in the reading pane of the mail window and the launcher, not in a separate window. To, Cc, Bcc, Subject, and From are all editable, with a signature button and a formatting bar: font, size, colour, bold, italic, underline, strikethrough, alignment, lists, and indent.
- **The original under your reply, as sent.** "On 2 Oct 2026, at 03:01, Name wrote:" and the original's own formatting in a quote with a blue bar, read only. **Remove Quote** sends only your text. Forwards include the original's From, Subject, Date, To, and Cc, and its attachments one by one.
- **Every mailbox of every account.** The mailbox menu groups each account, with Inbox, Drafts, Sent, Junk, Trash, and Archive first, and counts from the server.
- **Empty Trash and Empty Junk.** Empty counts what is on the server, asks you, and removes only those messages. Delete in Trash removes a message for good. Mark as Junk and Not Junk are in the ⋯ menu.

### Changed

- **Mail syncs only what you look at.** Each inbox keeps its newest 500 messages and a folder its newest 200 once you open it. Older mail loads when you scroll to it, and a body when you open the message. A first sync is seconds, not hours, and the store stays small.
- Hyper–M opens Mail at the newest message.
- Reply All fills To and Cc with names, without your own addresses. You can change them before you send.
- New Yahoo accounts no longer save a second copy in Sent: Yahoo files one itself.

### Fixed

- **Large Yahoo mailboxes now sync.** Yahoo refuses a search that would return more than 1,000 messages, so a big inbox stayed empty. Searches and fetches now stay inside each server's limit.
- **Closing a reply no longer crashes Jevcast.** Send and Discard could crash the app while the editor was on screen.
- A reply or forward sent during its undo time still goes when you archive or delete the original meanwhile.
- Text in your default colour is sent without a colour, so it no longer turns white or black for the reader.
- The Message-ID of a sent message uses your address's domain.

## [1.15.0] - 2026-09-30

### Added

- **Tailnet view.** Type `tailnet` or `/tailnet` to see your Tailscale devices, without phones and tablets. Each one shows its route (direct or relayed) and ping time, the data sent between it and this Mac, when its key expires, and its CPU, memory, free disk space, and uptime. Below it are the pages it shares, with their names and site icons, such as "T3 Code (Alpha)" for a Tailscale Serve share. Return opens a page, and typing part of a page's name in the launcher opens it from anywhere. A computer's row opens Remote Desktop (Windows App) or Screen Sharing, sends files with Taildrop, and copies an SSH command, its name, or its address. This Mac is read locally. Devices are asked only when you turn on **Check tailnet devices** in Settings › General, and only at their Tailscale addresses. `scripts/tailnet-agent.ps1` gives a Windows PC's load and every port it shares; it is read only and reached through `tailscale serve`.

## [1.14.0] - 2026-09-29

### Added

- **Jevcast accounts.** Jevcast can now sync mail itself, without Apple Mail. Add Yahoo (including @yahoo.ie), iCloud, Gmail, or another IMAP account with an app password in Settings › Mail › Accounts. The mail window, the launcher's Mail view, and mail search work as before, new mail arrives within seconds through IMAP IDLE, and changes and sent mail go straight to the account's servers. On servers that offer UIDONLY, such as Yahoo, every message syncs, not only the newest thousand in each folder. Apple Mail is never started, and Full Disk Access is not needed. **Read mail from** switches back to Apple Mail.

### Changed

- **Replies keep the message in view.** In the launcher, a reply now opens under the message it answers, with who it goes to, a clear text area, and Send and Discard. New messages and forwards use the same editor, in the launcher and in the mail window.
- **⌘R replies in the launcher's Mail view**, ⇧⌘R replies to all, and ⇧⌘F forwards, as in Apple Mail. Letters always type in the filter, so you can search for "receipt" or "Ryan". The footer shows the keys, and Send ⌘↩ and Discard esc while you write.
- **Undo Send.** A sent message waits 5 seconds, and the note counts down. Click Undo, or press ⌘Z, to bring it back. A new message, or Send on another one, sends a waiting message at once. Quitting Jevcast also sends it first, and waits for Mail to take it.
- The reply's To line lists who gets it, such as "Sam, and 5 others: Ann, Bob, …", marks a Reply-To address, and shows every address when you point to it. Apple Mail sets the final list when it sends.
- The composer's top has its own shade, and its title names the person, such as "Reply to Sam". Labels, values, and text line up.

### Fixed

- **No more blank replies.** Send looks dimmed until a reply has text, a forward has a recipient, or a new message has a recipient and a subject or text. If you press it before that, the composer says what is missing. A lone comma is not a recipient. Before it sends, Jevcast reads the text back from Apple Mail; when Mail did not keep it, nothing is sent and the reply comes back with the reason.
- **Apple Mail stays out of sight.** Opening the inbox no longer shows Apple Mail's window behind Jevcast. Jevcast starts Mail once, even when several changes ask at the same time, and hides it after it starts.
- A send that fails brings the draft back, with its text, instead of losing it. While another message with text is open, the failed one waits, and the note offers Show. A failure while no mail view is open shows in the launcher. When Mail may have sent the message, the note says to check Sent, so you do not send it twice.
- **Typed text is safe.** Reply, Forward, and New Message never replace a message you started. The open one comes back with "Finish or discard your open reply first." While you write in the launcher, the reader hides Reply, Delete, and Archive, and keeps the message you answer on screen, also when the list changes. Undo never loses text either.
- **Escape asks twice** before it discards a new message, forward, or reply with text, in the launcher and in the mail window. The note shows in the composer's footer, not over your text.
- Quill's draft goes only into the message it was written for, and not over text you changed while it wrote. Send waits until Quill finishes.
- "Sending…" shows while a message goes to Mail.
- The filter has the keys again after the composer closes, and the list comes back scrolled to your message.
- Mail keys follow the key caps on QWERTZ, Dvorak, and other layouts. ⇧⌘Z no longer undoes a send.
- A message saved with CRLF line ends now reads its last header correctly, so a base64 or quoted-printable body and a multipart boundary on that line are no longer missed.

## [1.13.0] - 2026-09-29

### Added

- **Terminal view.** Hyper–T, or `/terminal`, opens your login shell in the launcher, for quick commands such as signing in to a command-line tool. It is drawn by libghostty with your Ghostty font, palette, and keys, and takes the launcher's look: the panel glass behind the text, the launcher's margins, and an accent bar cursor. The bar above it shows the shell's folder. Escape closes it and the shell keeps running, so Hyper–T takes you back; ⌃[ sends Escape to a program. `exit` ends the shell. ⌘-click opens a web link. An existing Hyper layer gets T only when nothing else is on it.

### Fixed

- **Maps opens Maps.** An app or item whose whole name you type, such as Maps, now comes before the site search with the same keyword. A keyword with no such item, such as "gh", still searches first, and neither asks Jev.
- `ans` keeps its decimals where numbers use a decimal comma, so 1,5 stays 1,5 and not 15.
- **Old proposals stop blocking.** The background runner now expires a proposal after seven days, so it no longer holds back the next runs of its automation. The run folder and any journal stay.
- **Resume starts from now.** An automation you turn on again no longer runs once for the time it was paused.
- **Timers survive a restart.** `timers` lists running timers again after Jevcast restarts, so you can still cancel them. A timer that ended while Jevcast was closed does not show.
- **Mail keys.** In the mail window, F forwards, S flags or unflags, and C or ⌘N writes a new message. The ⋯ menu above a message has Forward, Flag, and Move To.
- An alert that the background runner opens no longer brings a running Jevcast to the front.
- `help <words>` lists only the matching features.
- A library import keeps aliases with spaces, such as "coding app", as Settings › Search does.
- The Clipboard view no longer says that ⇧Return pastes a multiple selection. It only copies.
- Settings › Keys lists ⇧Return, ⌘Y, ⌘R, ⌘⇧C, and ⌘Z in the launcher.
- Jev is no longer told about a Lock Screen command that does not exist.
- The README, the website, and the Mail setup view now say that HTML mail loads web images, fonts, and style sheets by default, and how to turn that off.

### Changed

- Scheduling a Quill task no longer posts a system notification. The launcher shows the task in the scheduled tasks list instead.
- Automation alerts hide automation names by default. A choice you already made stays.
- A copy imported from Codex cannot be turned on until you check its model, reasoning effort, and time zone in the editor and save it. Run Now also waits until its model and effort are checked. Jevcast no longer fills in a model or effort without asking.
- The README names Quill, and has new parts for Automations, the Clipboard view, Dictation, and the Hyper key.

## [1.12.3] - 2026-09-28

### Fixed

- **Mail marks every message you see as read.** The top message when the inbox opens and the next message after a delete or archive now count as read, as in Apple Mail. A message on screen when you come back to the window counts too. A message you mark unread stays unread until you move away. The first match of a search waits until the search stops changing.
- **Read messages stay read.** A refresh before Apple Mail writes its index no longer shows a read message as unread again. A read change that fails is tried once more.
- **Your phone matches.** When Jevcast started Apple Mail, closing the inbox now asks Mail to sync the changed accounts and waits 15 seconds before it quits Mail, so read status reaches the server.

## [1.12.2] - 2026-09-27

### Changed

- Notch alerts now grow out of the notch, morph between modes, and retract into it with smooth springs.

## [1.12.1] - 2026-09-27

### Changed

- Keys is now its own Settings tab, and Dictation is a part of the Voice tab.

## [1.12.0] - 2026-09-27

### Changed

- Notch alerts have a quieter design: a plain black island, grey text, colour only on the icon and main button, at most two buttons with a More menu, and a calmer open motion.
- Settings › Windows › Keys shows every keyboard shortcut in one place, with the Hyper key layer first; type "keys" in the launcher to open it.

## [1.11.0] - 2026-09-27

### Added

- **New notch alerts for automations.** Alerts grow out of the notch in a new design. On a screen without a notch they drop from the top centre.
- A running automation can show a small indicator beside the notch with its elapsed time. Click it to see its latest activity and Cancel.
- Questions show their answers as buttons. Reply opens a text field under the notch.
- Approvals show what will change, for example "12 moves, 3 to Trash".
- When more than one alert waits, they stack. Show lists up to four, each with its own buttons.

### Changed

- The notch panel takes keyboard focus only while you type a reply. Clicks outside the shape go to the app below.

## [1.10.1] - 2026-09-27

### Fixed

- **Gmail inboxes show their mail.** Apple Mail keeps each Gmail message once, in All Mail, and marks its Inbox, Sent, and labels in a separate table. Inbox, Unread, Flagged, and label mailboxes now read that table.
- All Mail shows each Gmail message once and counts it once.
- Unread counts for Gmail inboxes come from the messages in the Inbox.
- Archive, Move, and Delete on a Gmail message act on its Inbox, as Mail does. The message body still loads from All Mail.
- `--diagnose-mail` counts label members for each mailbox kind. It also shows the labels table, its columns and indexes, and the inbox count for each account by number.

## [1.10.0] - 2026-09-27

### Fixed

- **Mail shows all your mail.** The list no longer stops at 300 messages. It loads 200 at a time and loads more as you scroll near the end. The selection stays when more mail loads or new mail arrives.
- Inboxes from Exchange, Outlook, iCloud, Yahoo, and On My Mac count as Inbox, in any letter case.

### Added

- **All Mail.** The mailbox menu in the Mail view and the Mail window lists every mailbox except Trash, Junk, Sent, and Drafts. An email in both Gmail's Inbox and All Mail shows once. Inbox stays the default.
- Search also matches the body text that Apple Mail keeps for each message.
- When Apple Mail is closed, the list says new mail is not arriving and offers Open Mail. Mail opens in the background.
- `--diagnose-mail` prints message counts per mailbox kind, All Mail and inbox totals, whether Apple Mail runs, and query timings.

### Changed

- Mail reads its index through one kept connection with cached queries, and refreshes read only newer messages. On a 100,000 message test index, a page takes about 1 ms, All Mail about 18 ms, and a search under 35 ms.

## [1.9.2] - 2026-09-27

### Changed

- **Bigger views.** Mail, Calendar, Clipboard, and the other panel views open up to 1320 by 880 points, within the screen. The mail list is narrower, so the message gets most of the width.

## [1.9.1] - 2026-09-27

### Fixed

- Quitting Jevcast no longer hangs while clipboard history saves.

### Removed

- Dashboards are gone. The Automations window, Settings, and the launcher no longer show them.
- The launcher words "dashboards", "clients", and "metrics" no longer open a source.
- Jevcast no longer reads `dashboards.json` or `clients.json`. It does not delete them.

## [1.9.0] - 2026-09-27

### Added

- **Dashboards.** A dashboard card shows numbers from any JSON file on this Mac. Pick the file, then pick values from a list of what it holds. Give each value a label and a format: number, currency, percent, duration, or text. An optional "updated at" value shows how old the data is. A card can also run an automation with Refresh Now and open a file you choose.
- **Provider and model.** The automation editor and Settings › Automations › Agents show Provider (ChatGPT (Codex) or Claude), Model, Reasoning effort, and Speed. ChatGPT offers GPT-6 Luna, GPT-6 Sol, and GPT-6 Astra, with Normal or Fast speed. Claude offers Opus 5.5 at normal speed only. New automations start on GPT-6 Luna, High, Normal. Rows and details show "Provider · Model · Effort · Speed".
- **Read mail in full.** Wide HTML mail fits the message pane, and the pane scrolls both ways when needed. A text size control sets 75% to 150%. Space or the Expand button shows the message across the full panel. Escape shows the list again. ⌘O still opens the Mail window.
- Settings › Mail › Reading sets the list and message split, text size, fit to width, when a message counts as read, and a plain text preference.
- The Automations sidebar shows counts for each section.
- Settings has Advanced sections for rarely used options in Clipboard, AI › Jev, and Automations › Runner.

### Changed

- CLI default and Other are gone from the model menu. An empty model uses the provider default. An unknown stored model shows as "Custom: <id>" and does not change until you pick another.
- Claude runs always get `--model claude-opus-5-5` and never a fast setting.
- Jevcast runs only once. A second copy shows the launcher of the running copy and quits. A lock file in Application Support also stops a copy from another folder. Snapshot and diagnostic runs are exempt and start no watchers, runner, or Hyper key.
- Clients is now Dashboards in the Automations window, in Settings, and in the launcher. Type "dashboards". "clients" and "metrics" still work.
- Saved clients move to dashboards once, with their numbers kept. The old `clients.json` stays in place. A client of an unknown kind becomes a card with no values and a note.
- The "Meta metrics refresh" template is now "Refresh a data file", with placeholder paths. "Weekly client report" is now "Weekly report". Templates hold no personal folders or scripts.
- An empty section shows one message with one main button.
- Settings › General and Settings › Mail show the Quill and Jev switches as status only. Change them in Settings › AI.
- Settings captions are shorter. Dictation details moved into info buttons.

### Fixed

- The Automations window no longer opens with the sidebar cut off. A long prompt made the page wider than the window. A saved window size that is too small or off screen now opens at the normal size, and each open shows the sidebar.

### Removed

- Jevcast no longer adds client dashboards by itself on first run.

## [1.8.2] - 2026-09-27

### Removed

- The Clipboard view has no pins. Command-P, the Pin and Unpin actions, the Pinned chip, the pin mark, and "clip pinned" are gone.
- Settings has one Clear History button. Retention now applies to every entry.
- Entries pinned in an earlier version become normal entries and follow retention.

## [1.8.1] - 2026-09-27

### Changed

- A view opened with a Hyper key now closes the launcher on Escape. If a message or menu is open, Escape closes it first. The footer shows "Close" in place of "Back".
- The Clipboard view only copies. Return copies the selected entries and closes the launcher. Shift-Return, Option-Return, Command-1 to Command-9, and the Paste actions are removed.

## [1.8.0] - 2026-09-26

### Added

- **Clipboard manager.** The Clipboard view now keeps text, rich text, images, screenshots, files, videos, audio, PDFs, links, colors, and code. The list is on the left and a large preview is on the right.
- **Filters and search.** Chips filter by All, Pinned, Text, Images, Links, Files, Media, Colors, and Code. Search finds text, text in images, file names, source apps, and link hosts. "clip links" and "clip code" still work.
- **Keys.** Return copies. Shift-Return pastes into the app you were in. Option-Return pastes plain text. Command-P pins, Delete deletes and Command-Z brings it back, Space opens Quick Look, Command-K shows actions, and Command-1 to Command-9 paste a row. Shift-Up and Shift-Down select more than one row.
- **Actions.** Copy Text from Image, Save Image to Downloads, Open, Show in Finder, Open Link, Copy as Markdown Link, and text changes such as UPPERCASE, sort lines, JSON pretty print, URL encode, and Base64. A change makes a new entry and keeps the original.
- **Text in images.** Vision finds text in copied images on this Mac. Search finds it. You can turn it off.
- **History after restart.** On by default. Entries are kept in `~/Library/Application Support/Jevcast/Clipboard`, readable only by you. Choose how long to keep them, how many, and how much space they use. Pinned entries are never removed.
- **Ignored apps.** Copies from 1Password, Bitwarden, Keychain Access, Passwords, LastPass, and Dashlane are never recorded. Add or remove apps in Settings › General › Clipboard.
- **Hyper-V** opens the Clipboard view. It is added only when you have nothing on V.

### Changed

- Clipboard settings moved to Settings › General › Clipboard.
- Typing "clips" also opens clipboard history, and Return on "clip" opens the Clipboard view.

## [1.7.0] - 2026-09-26

### Added

- **Hyper key.** Turn it on in Settings › Windows › Hyper key. Caps Lock then becomes Hyper. Hold it and press a key to run an action. It is off by default.
- **Default keys.** M opens Mail, C opens Calendar, Space opens the launcher, and A opens Automations. H, J, K, and L send the arrow keys, and Shift still selects. The arrow keys move the window to a half, and Return fills the screen.
- **Your own keys.** Change or clear each key, record a new one, and pick an action, a key to send, or an app to open. Settings warns when a key is used twice.
- **Caps Lock light.** The light is on only while you hold the key. Caps Lock never types capitals while Hyper is on.
- **Safe remap.** Jevcast keeps your other key mappings. It puts Caps Lock back when you turn Hyper off or quit, and after a crash on the next launch.
- `--hyper-led-test` turns the Caps Lock light on for two seconds and reports the result.

## [1.6.0] - 2026-09-26

### Added

- **Automations.** A new Automations window, like Mail and Calendar, for background work. Run a script, an agent, or a script that asks an agent to diagnose it only when it fails. Schedules run from a signed helper inside the app, also while Jevcast is closed. Templates: Desktop tidy, Downloads sort, Meta metrics refresh, Weekly client report, and Morning brief.
- **Agents on your plan.** Agents run the `codex` (default) or `claude` command you are signed in to, so they use your ChatGPT or Claude plan. Access is read only unless you choose "Edit its folder" or "Edit its folder and use the network", and the CLI's own sandbox or tool list enforces it. There is no full-access level.
- **Approvals and undo.** An agent can propose file changes. You tick each one; Jevcast checks every path, makes the change itself, keeps a journal, and can undo it. Deletes go to the Trash. An agent can also stop and ask you a question.
- **Notch alerts.** Automations stay silent. A card drops from the MacBook notch only when a run needs your answer or approval, or fails. No system banners.
- **Codex automations.** Jevcast reads `~/.codex/automations` (never writes to it), shows each schedule and status, and imports a paused copy. A copy stays blocked while its Codex original is active.
- **Clients.** Meta ads metrics cards from local dashboard files, with each source's freshness.
- **Settings › Automations**: Runner, Agents, Alerts, and Codex & Clients.
- **Quill model picker** and **Fast** as its own switch.

### Changed

- **Luna is now Quill.** Luna is the name of one OpenAI model, so the writing helper has its own name. Your settings, key, tasks, and history carry over.
- **Reasoning effort** offers Low, Medium, High, Extra high, and Max. The old "Fast" effort reads as Low.
- **Quill tasks** no longer post system notifications. A failed task shows in the notch; successes stay in the history.

## [1.5.1] - 2026-09-25

### Fixed

- **Faster Calendar.** Month and week views fetch the months either side in the background and keep them after the view closes, so ↑, ↓, and switching to Week show at once. The List view and calendar search read events off the main thread, and Copy Details no longer reloads the list.

## [1.5.0] - 2026-09-24

### Added

- **Views in the launcher.** Mail, Calendar, Tasks, Clipboard, and Clean Up open inside the panel instead of a separate window. The search field becomes the view's filter, Escape goes back one level, and ⌘O opens Mail in its own window.
- **Mail with a preview.** The inbox list on the left and the message on the right, half and half. ↑ and ↓ move through messages, a previewed message is marked read after a second, ⌫ deletes, and Return opens it in Apple Mail. Unread messages show a dot and a bold sender. The inbox refreshes by itself while it is open.
- **Calendar views.** Month (the default), Week, and List. ← and → switch views, ↑ and ↓ move to the previous or next month or week. Events show in their calendar's colour, all-day events as a bar, and today in red.
- **Functions with `/`.** Type `/` to list everything Jevcast can do, in groups, with one line on what each does. `/cal` filters the list, Tab completes, and Return runs it. `/` followed by a real path, such as `/Applications`, still opens the folder.
- **Your library with `$`.** `$` lists only your own commands, workflows, and snippets. `$120` is still an ordinary search.
- **Time zones.** "6pm atlanta time in uk time", "3pm uk in pst", or "now in tokyo" converts a time between places. Return copies the answer, and Jev understands looser wording.
- **Dictation.** Hold Right Command, speak, and let go: the text goes into the app in front. Speech is transcribed on this Mac, audio is never saved or sent, and an optional Luna clean-up has its own switch. "dictation history" lists what you said. Off by default; turn it on in Settings › Dictation.
- **Clean up.** "cleanup" or "cool down" lists background work to stop: booted simulators, dev servers idle for an hour or more, dev processes left over from closed terminals or agents, and Docker Desktop with no containers. Heavy processes are listed but never checked. T3 Code, Chrome, Codex, Finder, Mail, your terminals, the app in front, everything those apps started, launchd jobs, and system processes are never offered. Manual only. ⌘K offers Stop Now and Always Ignore.
- **Library export and import.** Settings › Library saves your commands, workflows, snippets, search keywords, and app aliases as one file. Import shows every command's full text first and adds only what is new.
- **Hide from Search** on apps, and names that match without spaces, such as "t3code".

### Changed

- **A simpler menu bar menu.** Open, then Mail, Clean Up, and Luna Task Results. A warning row shows only when a feature you turned on needs a permission or a key.
- **Settings, reorganised.** Tabs are General, Search, Library, Windows, Voice, Dictation, AI, and Mail. General lists every permission in one place and every feature that uses the network. AI holds Jev, Luna, and Usage. Long explanations moved behind ⓘ.
- The "Jev picked … Press ⌘Z to undo" strip is gone. A Jev pick shows "Jev · ⌘Z" on its row instead.

### Fixed

- Scrolling with a trackpad or mouse wheel did nothing inside the launcher.
- Mail actions failed with an AppleScript syntax error.
- Apps, links, and files Jevcast opens come to the front.

## [1.4.0] - 2026-09-24

### Added

- **Scheduled Luna tasks.** Type a schedule and a request, such as "every weekday at 8am brief me on my meetings and unread email", "summarise my reminders every evening at 7", or "every 2 hours check my unread mail". Tasks run on this Mac while Jevcast is open, read only the data they name and you allow, and post a notification with the result. Click it to read the whole result. Each result is saved as Markdown in `~/Library/Application Support/Jevcast/Luna Tasks`. "task results" lists past runs; "scheduled tasks" lists tasks with Run Now, Pause, and Delete. A run missed by more than three hours is skipped and noted.
- **Calendar and reminders** and **Unread mail list** switches in Settings › Luna, for tasks that read events, reminders, or unread mail. Both are off at first, and the single-message mail switch does not allow the unread list.
- **Jev in two steps.** Jev also names the kind of request in a second small call at the same time. When the kind disagrees with the pick, Jev chooses again among every candidate of that kind. A window move that loosely names a running app asks which app. On by default; turn it off in Settings › Input.

### Changed

- One click runs a row, and the pointer highlights the row under it. Double-click is no longer needed.
- With nothing typed, the launcher is the search bar alone. Favourites still rank higher in results.

### Fixed

- A square light edge could show around the launcher's rounded corners in Dark Mode.

## [1.3.0] - 2026-09-24

### Added

- **Things on your Mac, with verbs.** Rows from each source below have their own actions. Return runs the first one, and ⌘K lists all of them.
- **Scheduled tasks.** "scheduled tasks", "what runs at login", or "cron" lists launch agents, daemons, crontab lines, and timers. Each row shows its schedule in plain words, the next run, whether it runs or failed, and warnings for a missing program or an unusual folder. Agents can run now, turn off, or turn on. "scheduled tasks failing" shows only jobs whose last run failed.
- **Calendar and Reminders.** "calendar", "agenda", or "my day" lists events. Join Call opens Zoom, Meet, or Teams links. Your own events move 15 minutes or an hour later. "reminders" lists open reminders, overdue first, to complete or move to tomorrow.
- **Make reminders and events.** "remind me to call mum at 5pm", "remind me to stretch in 20 minutes", and "add event lunch with Sam friday 1pm".
- **Contacts.** "contact sam" finds a person to email, message, call, or copy.
- **Browser tabs and history.** "tabs" lists tabs in Safari, Chrome, Arc, Brave, Edge, Vivaldi, and Dia, to switch to, close, or copy. One row closes duplicate tabs. "history <words>" searches browser history on this Mac.
- **This.** Type "this", or an action such as "copy link", to act on the page, Finder selection, or selected text in front: copy a link, make a reminder, open the page in another browser, or compress files.
- **Luna.** An opt-in writing model, GPT-6 Luna through OpenRouter, with Fast, High, and Max effort. "ask …" answers a question in the panel. With selected text, Luna fixes, shortens, rewrites, summarises, explains, or translates it, and Return replaces the selection. Jev decides what a request means; Luna only writes text.
- **Mail.** "mail" or "inbox" opens a keyboard-first mail window on top of Apple Mail: Inbox, Unread, Flagged, each account's mailboxes, a message list, and a reading pane. Archive, delete, move, flag, reply, forward, and new messages go through Apple Mail, which starts hidden. Luna can summarise a message or draft a reply. "mail <words>" searches from the launcher.
- **Settings › Luna.** Effort, an OpenRouter key, a switch for each kind of context Luna may read, and an activity log of each request without its text.
- `--diagnose-source '<query>'` and `--diagnose-mail` for checks on a real Mac.

### Privacy

- Luna is off until you turn it on. Selected text and mail go to Luna only when you turn on each one. Jevcast checks every request against those switches before it sends it.
- HTML mail shows with scripts off, and every remote load is blocked, so tracking pixels do not load.
- Jevcast reads Apple Mail, Calendar, Reminders, Contacts, browser tabs, and browser history on this Mac only. Each needs its own macOS permission.

## [1.2.3] - 2026-09-23

### Changed

- ⌫ stops a port's process, not Return, and the launcher stays open. The first ⌫ asks and the second stops. The row disappears and the strip says what stopped. ⌫ stops only after you pick the row with ↑↓ or a click, so typing still deletes text. ⌘⌫ stops the selected process at any time.
- Return on a port opens `http://localhost:<port>` in your browser.
- ⌘K on a port adds Stop, next to Force Stop.

## [1.2.2] - 2026-09-23

### Added

- A richer port list. Each listening process shows its CPU, memory, uptime, the script or module it runs (such as `vite` or `http.server`), its project folder, and whether it is open to your network or to this Mac only. The numbers refresh every two seconds while the list is open.
- Your own servers come first. macOS services are marked and warn that they may start again. Another user's processes, such as root's, cannot be stopped from here: Return explains why, and ⌘K copies the `sudo kill` command.
- ⌘K on a port: open `http://localhost:<port>`, show the folder in Finder, force stop, copy the PID, or copy the full command line.

## [1.2.1] - 2026-09-23

### Added

- Jev through OpenRouter. Paste an OpenRouter key (`sk-or-…`) in Settings › Input and Jevcast sends Jev requests to OpenRouter's proxy of the TypeSafe API, with the model `typesafe/jev-1.13`. A TypeSafe key still goes to TypeSafe directly.
- Settings › Usage shows the cost OpenRouter reports for each request. TypeSafe requests are priced from their tokens.
- `--store-jev-key` saves a key from standard input.

### Fixed

- A reply from a dated Jev build, such as `typesafe/jev-1.13-20260917`, was rejected.
- An account without credits (HTTP 402) now says so.

## [1.2.0] - 2026-09-23

### Added

- **Settings › Usage.** Jev requests, input and output tokens, cost, Jev picks, and requests answered from memory, for 7 days, 30 days, and all time. Counts come from TypeSafe's usage figures and stay on this Mac.
- **Memory.** When you choose a result for a request, Jevcast remembers it on this Mac. The same request then needs no Jev call. ⌘Z on a remembered or Jev pick undoes it and forgets it.
- **Open and arrange.** "notes left half" or "open notes on the left" opens the app, then arranges its window.
- **Site search in plain words.** "search github for swift ui". Jev can also pick a site, and the rest of the request becomes the search.
- **Apple Shortcuts.** Your Shortcuts appear in the launcher, and Jev can choose them.
- **Menu items.** The menus of the app you were using, such as Safari's "New Private Window", are searchable. The Window menu and recent-document menus are left out.
- **Workflows** in Settings › Commands: run several steps from one name, such as open Xcode, Left Two Thirds, open Terminal, Right Third.
- **Snippets** with `{date}`, `{time}`, and `{clipboard}`. Shift–Return pastes.
- **Timers.** `5m tea`, `timer 10 min`, or "remind me in 20 minutes to call Sam". Type `timers` to cancel one.
- **Emoji and symbols.** `:tada`, `emoji party`, or `symbol arrow`. Return copies, Shift–Return pastes.
- **Calculator history.** Use `ans` in a sum, such as `ans * 2`. Type `history` for recent answers.
- **Clipboard.** Pin items from the ⌘K menu, filter with `clip links`, `clip numbers`, `clip colours`, `clip emails`, or `clip code`, and paste with Shift–Return.
- **Ports.** Plain phrasing such as "stop whatever is running on 3000". ⌘K adds Force Stop and Copy PID.
- **Your commands** can take text: put `{input}` in the command, then type the name and the text. `{input}` is passed as a quoted argument, never as command text. A command can copy its output or show it in a notification.
- `--diagnose-jev "request"` runs requests through the launcher with the stored key and prints the pick and the tokens used.

### Changed

- Jev is smarter about when to run. A whole-name match, a sum, a URL, a keyword search, a timer, or a port lookup skips it. The same request within 10 minutes reuses the last answer.
- Jev's candidate list puts matches for the request's words first, from apps, System Settings panes, commands, workflows, Shortcuts, snippets, and menu items. It can also route to Find Files, Recent Files, Clipboard History, and Timers.
- File search understands more everyday phrasing: "pdfs from last week in downloads", "documents I changed last month", "screenshots from yesterday". New dates: last week, this month, last month.
- Your commands moved to a new Settings › Commands tab with workflows and snippets.
- Local builds are signed with your Apple Development certificate when you have one, so macOS keeps Accessibility access across rebuilds.

### Fixed

- A sum with a spaced division, such as `100 / 4`, was read as a file path.
- A custom command with a lot of output could hang.

## [1.1.0] - 2026-09-23

### Added

- Port commands. Type `port 3000`, `kill 5173`, or `:8080` to see which process listens on that local TCP port, then press Return twice to stop it. `ports` lists every listener.
- Built-in commands: Sleep Display, Sleep Mac, Toggle Dark Mode, Show and Hide Hidden Files, Restart Finder, Restart Dock, Empty Trash, Eject All Disks, Mute and Unmute Sound, Screenshot Area to Clipboard, Copy Local IP Address, and Keep Mac Awake for 1 Hour. They run fixed programs with fixed arguments and no shell.
- Your own commands in Settings › Search › Your commands. Type a command's name to run it with `zsh -lc` from your home folder.
- Disruptive actions, such as Empty Trash and stopping a process, need a second Return. The strip says what will happen.

### Changed

- Jev now reads every request after a short pause, typed or spoken, not only long phrases. Sums, typed URLs, keyword searches, and port lookups skip it because they already have one answer. A whole-name match you typed stays first.
- Jev can choose built-in commands, your own commands by name, and the port command. It never sees or writes command text.
- Jev requests are smaller: at most 120 candidates, with favourite, recent, and running apps first.
- While voice input listens, the MacBook's built-in speakers are muted, so their sound is not transcribed. They come back when listening stops. Headphones and other outputs are not changed.

## [1.0.0] - 2026-09-22

First public source release. Build on a Mac with Xcode 26 or later. No signed binary is included.

### Added

- A welcome window on first launch: choose a shortcut and try it, allow Accessibility, turn on voice, open at login, and check for updates. It warns if the app runs from the disk image or Downloads. **Help › Welcome Guide** opens it again.
- **Check for Updates…** in the app menu and the menu bar. An automatic check runs once a day and can be turned off in Settings › General. The app never downloads or installs updates itself.
- A **Help** menu with the welcome guide, the website, the source code, and issue reporting. About shows the license.
- One universal app for Apple silicon and Intel Macs.
- Settings › Input explains natural-language matching and links to TypeSafe for a key.

### Changed

- The public-facing app name is now Jevcast, and the repository is `RyanErkal/jevcast`. Internal bundle and executable identifiers stay stable.
- The shortcut on a new install is Option–Space. Earlier installs keep the shortcut they had.
- Voice input starts off on a new install. Earlier installs keep their setting.
- On macOS 26, Settings and the welcome window use the current system design.
- Preferences, the Keychain item, and logs share one identifier. A stored TypeSafe key moves to the new Keychain item automatically.

### Fixed

- The six sixth-of-screen window actions showed no icon.
- A sum or conversion no longer lists window actions or settings that share one word with it, such as "Left Two Thirds" for `12 * (8 + 2)`.
