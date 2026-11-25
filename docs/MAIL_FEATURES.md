# Mail in the launcher

Version 1.21.0 keeps reading, composition, account recovery, and mail tools inside
the launcher. Open Mail with Hyper–M or `inbox`. The gear at the bottom of the
sidebar opens Mail Settings (Rules, Offline & Storage, Aliases & Signatures, and
the other tool pages); while the sidebar is hidden, they are under Mail Settings in
the list's ⋯ menu and in ⌘K. Escape returns from a tool to the previous draft or list.
Escape on an open draft closes it and keeps it in Drafts.

## Use and limits

| Feature | Behavior |
| --- | --- |
| Offline & Storage | Select recent mail, selected folders, or all history for each native account. Background work advances in batches. Folder coverage and errors remain visible. All history is complete only after the download finishes. |
| Search and filters | Local full-text search uses indexed bodies. Sender, recipient, date, account, folder, unread, flag, and attachment filters are available. Recipient and attachment results are a lower bound while bodies are missing. |
| Filter chips | Under the list's title: Unread, Flagged, and Attachments turn their filter on or off in one click, with no Apply. They set the same fields as the filter form. "+N" counts the form's other filters (sender, dates, and so on) and opens the form; × clears every filter. While the filter field has text, the search scope (This mailbox, All accounts) takes the chips' place and the title says what was found ("3 results"; the full sentence is in its tooltip). Both lines keep one height, so the list never moves when a search starts or a filter turns on. |
| List | Rows sorted newest first, with 8 or more rows, sit under quiet date labels: Today, Yesterday, This Week, Last Week, each earlier month of this year by name, then each earlier year. The week starts on the Mac's first weekday. Labels are not rows you can select: ↑↓, ⇧-click, Select All, and loading more step over them. Outbox and short lists have none. The selected row has an accent wash; the other rows of a multi-selection have a lighter one with a thin accent outline, and each selected row has exactly one highlight. On a selected row the date, subject, and preview keep at least 4.5:1 contrast; on the other rows the sender, subject, and preview do too, with the preview quietest and read rows quieter than unread ones. A click on the row already selected shows it again, closing connection details or setting an open draft aside; ⇧-click and ⌘-click only select, and the filter keeps the keys. Only a click or key in the list itself changes its selection. Each row's spoken label names what it shows: unread, the sender, VIP, the subject, the message count, the date, flagged, attachments, and the account in a mixed list. Hover over the subject to see its account. The dot beside the sender marks unread mail. |
| Row actions | Under the pointer, a row shows Archive, Delete, and Mark as Read or Unread over the end of its first line; the date stays underneath. Right-click a row for Reply, Reply All, Forward, Archive, Mark as Read or Unread, Flag, Snooze, Move To, Junk, Delete, and Delete All from the sender, each with its key. When the clicked row is in a selection of several rows, the menu acts on all of them, and every loaded message of those conversations decides what it offers and leaves out what acts on one message only (Reply, Reply All, Forward, Snooze, Junk, Delete All from the sender). Otherwise it acts on the clicked row, which becomes the message on screen (it stays unread). Each mailbox offers only what it supports: Drafts offer Edit Draft (Jevcast accounts), Flag, Move, and Delete; Sent and Trash have no Junk, Snooze, or Delete All from the sender; Junk has no reply, Archive, or Snooze; Archive has no Archive. Several rows in Trash have no Delete, because there a delete is permanent and goes one message at a time; ⌫, ⌘K, the reader's Delete, and Delete under the pointer then say "Select one message to delete it for good." and delete nothing. A delete for good runs only on the message on screen while no other row is selected; Delete under the pointer on another Trash row first makes it the message on screen. The message on screen is always one of the selected rows, also after a sync removes it: the focus moves to a row that is still selected. Each item runs the same action as the reader and ⌘K, so Undo and the question before Delete All from a sender stay the same. One rule decides what each mailbox allows for the keys, ⌘K, the reader's bar (which hides or dims what is refused, such as Snooze in Sent), the row menu, the bar for several rows, and the list's ⋯ menu; a key for an action the mailbox does not allow, such as ⌃⌘S in Sent, shows a note and does nothing. |
| Conversations | Provider thread IDs and downloaded Message-ID references group messages within one account. Similar subjects alone never merge messages. Missing thread headers leave separate rows. Each loaded conversation has one list row; its downloaded replies appear together in the reader. Click a sender to target that reply with reply, flag, and attachment actions. Delete moves all loaded conversation replies to Trash; in Trash, permanent Delete targets one selected message. Repeated HTML quotes hide behind a small ••• pill below each reply; click it, or Tab to it and press Space, to show them. Show Quoted Text in the reader's ⋯ menu and in ⌘K opens every quote in the conversation; another conversation starts with them closed. When the conversation loads again, such as after Fit Wide Mail to Width, the mark is on the reply the actions use. Each reply shows its sender's initials and a short date (the full date in its tooltip). The reply that the actions use has an accent mark on its leading edge; clicking a sender moves the mark there without reloading the conversation, but scrolls that reply to the top of the pane. |
| Bulk actions | Select loaded conversation rows with Command-click or Shift-click. Multiple selected conversations include their loaded member messages. With two or more selected, a bar below the list shows the count with Archive, Delete, Mark Read, Mark Unread, Flag, Move To (rows of one account), and Deselect; the list's ⋯ menu keeps the same entries. Delete is ⌫'s delete, with its Undo note; the others are the bulk actions. Read, flag, archive, move, and Trash actions report partial failures. Undo uses the retained identities. Bulk Trash does not permanently delete. Escape first leaves an expanded message, then narrows a selection of several rows to the message on screen, and only then leaves Mail. |
| Offline changes | Read and flag operations can replay after reconnect. Moves with an uncertain result wait for review. Account, folder, UIDVALIDITY, UID, and available Message-ID values are checked before replay. |
| Recipients | Chips validate addresses. Suggestions use local mail. Contacts access begins only after the user selects the Contacts option. |
| Aliases | Add only an address already authorized by the provider and explicitly confirm that authorization. The provider still decides whether to accept it. The account remains the credential and SMTP envelope owner. |
| Server drafts | Edit Draft imports a selected server draft with its attachments. Local and remote conflicts are kept. Saving and cleanup use exact server references; uncertain acknowledgements need review. |
| Rules | Enabled rules act on newly observed Inbox arrivals after startup. Existing mail requires Preview and Apply. Actions are read/unread, flag/unflag, or move to a folder in the same account. Rules cannot permanently delete. |
| Smart mailboxes and senders | Save predicates, preview matching downloaded messages, and open a result. VIPs show a star. Blocking creates an exact sender rule targeting the account's Junk folder. |
| Notifications | Off by default per account. Notices use the notch, support private previews and quiet hours, and suppress initial history and backfills. They require Jevcast running. |
| Reading | Opening Mail, a reload, a search, or a delete selects a message but leaves it unread. A message counts as read (after the time set in Settings › Mail) only once you choose it or act on it: a click on its row, ↑↓, Return, Space, a reply, or a scroll (trackpad or mouse wheel) or click inside the message. Scrolling done by Jevcast itself does not count. Within one session, Mail opens again on the mailbox and message you left, or on the newest message when that one is gone; a message picked in the search or a mail link still opens where it belongs. Opening a message that way clears list filters that could hide it, and a note says so; it also empties the search text and closes connection details. The sidebar stays shown or hidden as you left it, also after a restart. |
| Space | With an empty filter, Space scrolls the open message down one page, and at its end goes to the next message; ⇧Space scrolls up. Return still expands the message. HTML mail runs no scripts, so each Space compares a small picture of the page before and after its own page down: when that press moved nothing, the next message opens. There it takes one more press than plain text. A press while the last one is still measured is ignored, and a page that changes by itself, such as an animated image, may need another press. Until the message's page has drawn with content, such as a conversation whose first reply is still loading, Space does nothing. A page that cannot load shows "This message could not be shown.", never the message before it. |
| Text size | ⌘+ (or ⌘=) and ⌘− change the message text size in steps of 25%, from 75% to 150%; ⌘0 returns to 100%. The reader's ⋯ menu shows the size and has the same three items. |
| Reader | One header for a message and a conversation: the sender's initials, name, and address, the subject, the recipients, and a short date (the full date in its tooltip), as in the list. In a conversation it shows the reply that the actions use. The header draws at once; while the body loads, grey lines hold its place, and a spinner shows only after 0.15 s. Text mail and conversations sit on the pane's own surface in light and dark appearance; mail with its own page colours shows as a light card, inset with rounded corners. The card is the view, not a change to the mail: the sender's own page colours, such as a dark page with light text, stay as sent. When you move to another HTML message, the old body hides until the new one starts to draw. The bar holds Archive, Delete, Reply, Read or Unread, Snooze, ⋯, and Expand. Click Reply to reply; its arrow offers Reply All (⇧⌘R) and Forward (⇧⌘F). The ⋯ menu holds Flag, Junk, Move To, Export, Text Size, the view settings, Summarise, and Delete All from a sender. |
| Composer | The header holds To and Subject; Cc/Bcc shows Cc, Bcc, and From. From also shows with more than one sending account, as a quiet line with a small chevron; its menu picks the account and has Insert Signature. The footer names what you write ("Reply to Sam") and holds Attach (⇧⌘A), Aa, Send Later, Discard, and Send. In a narrow pane the name gives way first, then Send Later shows as its icon with its name in the tooltip; Send and Discard keep their names. Aa shows or hides the formatting bar; it is hidden at first and stays as you leave it. ⌘B, ⌘I, ⌘U, ⌘], and ⌘[ format the text either way. The launcher's footer shows only keys the composer does not: Attach, Discard, and Save Draft. |
| Signatures | A new message, reply, forward, or mail link starts with the sending account's signature (or the alias's) below a blank line; a reply's original goes below it. Changing From swaps the signature while the text still ends with exactly the blank line and signature Jevcast put in, or takes it out for an account without one. Once any edit breaks that, the signature is yours for good, and From never changes your text again. Insert Signature does nothing while the text already ends with that signature, and replaces an unchanged signature Jevcast put in before (such as another account's before you changed From), so the text never holds two. A signature alone does not count as text, so an untouched draft still closes without a copy and an empty reply still cannot go. A draft opened again, restored, scheduled, or from a server never gets a second one. Mail Settings › Aliases & Signatures turns this off; Insert Signature still adds one by hand, below a blank line, and a signature added that way does not count as text either. |
| Columns | Drag the line between the sidebar and the list, or the list and the message, to resize. Widths are kept after a restart, and every width leaves the message at least 420 points, so the smallest panel (860) stays readable. Double-click a line to go back to the width that follows the panel. Each Layout setting (Balanced or Wider message) keeps its own list width: dragging under one never changes the other, and double-clicking the line resets only the one on screen. Expanding a message, hiding the sidebar, and opening the composer slide (not with Reduce Motion), and the message does not load again. |
| Status | A quiet line at the bottom of the sidebar says "Updated 2 min ago", "Checking…", "Offline", or "1 account needs attention". The last opens that account's connection details. An account that failed or has changes to review shows a warning sign in place of its dot; click the sign, or right-click the account for Connection Details. With the sidebar showing, Check for new mail reports in this line, not in a note; errors still show as a note. For Apple Mail the line shows the last check Jevcast asked Apple Mail for; checks of Jevcast's own accounts never count there. |
| Drafts | Escape never deletes a draft. It closes the composer, keeps the draft in Drafts, and shows “Draft saved.” with Open once the draft is written; if the write fails, Mail says so and the draft stays open in memory. Leaving Mail does not end the note: it shows again for its full time when Mail opens. Quitting waits for the draft to be written (90 seconds at most). Only a draft exactly as Jevcast filled it in closes without a copy; a change to any field, such as a Bcc, the Subject of a reply, the sending account, or bold or a link on the signature alone, keeps it. A draft restored (also after a restart) or opened from Drafts is always kept. A closed draft stays closed after a restart. Clicking another message closes the draft the same way. A closed draft never blocks a new one: a new message, reply, forward, or mail link opens, and the closed draft stays in Drafts. Edit Draft on the draft you closed shows it again. Discard (or ⇧⌘⌫ while writing) deletes it; a draft with any change, such as a Bcc alone, needs a second press, and a held key does not count as the second press. ⌘⌫ stays with the text, where it deletes to the start of the line. A draft whose send failed or may have gone keeps its warning when it is closed, also after Escape. Open Draft in Outbox opens the newest copy of that draft (open, closed, or in Drafts), and Allow Resend applies to that copy. Edit Draft on a server draft that a draft on this Mac already holds opens that draft, with any review it needs, and never makes a second copy. While a send of that draft runs or may have gone, Edit Draft opens nothing and points to Outbox. |
| Snooze | Local to this Mac. Hides the message from Inbox and Unread until its return time. Other folders and other devices retain it. ⌃⌘S opens Snooze for the selected message (Jevcast accounts). Snooze in a row's menu first shows that message in the reader, as a click does (an open draft closes by the usual rules), then opens Snooze there. Later today (three hours on, to the full hour, while still today), Tomorrow morning (8:00), and Next week (Monday 8:00) snooze in one click; the date picker sets any other time. |
| Send Later | Saves the entire draft and attachments before leaving the composer. Requires Jevcast running and the Mac awake. Missed times wait for review. Interrupted or uncertain dispatches require a Sent check. Startup never resumes them. |
| Undo | Archive, Delete (to Trash), and Move show a note with Undo for eight seconds; ⌘Z does the same. The note says what happened, such as “Moved 12 messages from Ada to Trash”, and other notes show above it, never in its place. While the pointer is on the note, its time stops; after the pointer leaves, the note has the time it had when the pointer came, and at least three seconds. ⌘Z shows only on the note it will undo: while a send waits, that is the send. While a text box has the keys, such as the composer, the note shows no ⌘Z, because ⌘Z there undoes typing; its Undo button stays. Jevcast waits for the change to finish, also when you press Undo at once, and for any bulk action that is running, then moves back only the messages that the change moved (when it still cannot run, a note says so); when some of them failed to move, Undo still puts back the others. Undo of Mark Read or Flag on several rows gives each message its own earlier state. A Jevcast account finds each one in its new folder by exact Message-ID and refuses when none or more than one matches. A delete in Trash is permanent and has no undo. The five-second Send undo keeps its fixed time, because the send starts when it ends. |
| Delete All from a sender | In the reader's ⋯ menu. It first asks, with the count and the sender, then reads each counted message again from the mail index and moves to Trash, with Undo, only those that still match what was counted: the same account, mailbox, message, sender, date, and subject. A message that cannot be read again stays. It never counts a message in Trash and never deletes for good. When fewer moved than were counted, the note says so ("Moved 3 of 5 messages"). It is refused in Trash and Sent. |
| Actions menu | ⌘K lists every action for the selected message with its key. |
| Invitations | A message with a calendar part shows a card: title, time, place, organiser, and your answer. Accept, Maybe, and Decline send a standard calendar reply to the organiser from the account that received the message (Jevcast accounts only). Add to Calendar saves the event on this Mac. A cancellation and another guest's answer show as information only. |
| Unsubscribe | A small link beside the sender in the reader's header, shown when the message has a `List-Unsubscribe` header. After you confirm, Jevcast sends the list's own unsubscribe email from that account, or opens the list's https page in your browser. Jevcast does not request the page itself. |
| Mail links | A mail address clicked in a message starts a new message in Jevcast. Settings › Mail › Default mail app makes Jevcast open mail links from other apps; macOS may ask you to confirm. |
| Folders | Right-click an account or folder: New Folder, Rename, Delete Empty Folder. Only your own folders can be renamed or removed. A folder with messages or folders inside is refused, and nothing is deleted. A renamed folder downloads its headers again when opened. |
| Keys | ⌘E or ⌃⌘A archive (while text is selected in the filter, ⌘E is the text's own Use Selection for Find; ⌃⌘A always archives), ⌃⌘S snooze, ⇧⌘L flag, ⇧⌘U read or unread, ⇧⌘J junk, ⇧⌘M move (type a folder name, then Return), ⌘1 to ⌘7 the main mailboxes, ⌘+ ⌘− ⌘0 text size. With an empty filter: Space and ⇧Space page through the message, Return expands it, ⌫ deletes. ⌘⌫ deletes also while the filter has text. ⌫ with ⇧, ⌥, or ⌃ never deletes, and a held key never deletes. While writing: ⌘Return sends, ⇧⌘A attaches files, ⇧⌘⌫ discards (with no draft open, ⇧⌘⌫ does nothing), Escape closes and keeps the draft; ⌘B, ⌘I, ⌘U bold, italic, underline, and ⌘] ⌘[ indent. Letters always type in the filter. |
| Import and export | `.eml` and `.mbox` imports go to a separate owner-only archive. Preview reports counts and malformed entries. Imports deduplicate raw bytes. Source files are preserved. The import limit is 128 MB per file. Export retains message and attachment bytes. |

Scheduled mail, snooze, rules, and the imported archive are stored under
`~/Library/Application Support/Jevcast/MailFeatures`. Drafts and send receipts
remain under `MailComposition`; the native index and offline queue remain under
`Mail`. Tokens and passwords stay in Keychain. Export destinations are selected
by the user.

Clearing cached bodies removes local downloaded copies, not server messages.
Changing offline policy does not delete server history. Export does not mark a
message read, move it, or send anything. A downloaded body is required to export.

## Acceptance

Automated checks use fake IMAP/SMTP servers, temporary stores, and demo data.
They do not establish live SMTP delivery, provider alias acceptance, phone draft
sync, Contacts permission behavior, printing, real keyboard input, or daily-use
reliability. Account reconnect and read-only sync are separate live checks.

Google OAuth projects left in Testing can issue refresh tokens that expire
after seven days. Reconnecting accounts does not change that provider setting.

Encrypted mail and a week-long cutover exercise are separate follow-up work.
Version 1.22.0 adds folder changes and default mail-app registration; neither has a live check yet. The features above do
not establish complete Apple Mail parity.

## Review fixes checked on 2026-11-25

Offline checks cover deletes for good in Trash after a sync and from Delete under the pointer, Outbox Open
Draft and Allow Resend on the newest copy, the warning of a failed draft, Edit Draft on a server draft held
on this Mac, drafts after a restart, Insert Signature, Undo behind a bulk action, Delete All from a sender
against a reused row, the reader's bar in Sent, menus for several rows, Space before a page has content, a
page that fails to load, the row date at midnight, list contrast, and the placeholder at 860 points. Not
checked live: a real click on the selected row, real keys, and a real provisional load failure.

## Composer and layout checks on 2026-11-25

Offline checks cover automatic signatures (new, reply, swap on a From change, an edited signature, rich
text, a draft opened again, the setting), column width clamping at 860, 980, and 1320 points, kept and
reset widths, badge abbreviation, the status line's text, formatting keys, and the Outbox note. Mail demo
snapshots rendered, including `mail-compose-formatting`, `mail-workspace-columns`, and
`mail-workspace-attention`. Not checked live: the motion, dragging a divider and its pointer, the
formatting keys and ⇧⌘A with a real keyboard, and the status line against real sync.

## Version 1.23.0 checks on 2026-11-10

Offline checks cover Undo against the fake IMAP server (the exact message returns, an older message in the
same folder stays, and a second undo is refused), the Undo note's state after a delete and after a failed
delete, search-word marking, file kinds, initials, and the plain-message page style. Mail demo snapshots
rendered in dark and light appearance. Not checked live: Undo on a real server, the menus with a real
keyboard, and motion.

## Version 1.22.0 checks on 2026-11-09

Offline checks cover the invitation parser and reply text, the calendar part of a sent reply, `mailto` and
`List-Unsubscribe` parsing, folder name rules, the conversation document, and the list's footer keys. The
Mail demo snapshots rendered, including `mail-invitation` and `mail-thread`. Not checked live: a real
invitation reply and how each calendar server records it, a real unsubscribe email, folder changes on a real
server, the default mail app prompt, and the ⇧⌘M menu with a real keyboard.

## Release checks on 2026-10-09

The final offline suite ran 1,184 tests: 1,181 passed, three skipped, zero
failures. The skipped tests require real user files or the real Trash. The
suite covered fake IMAP/SMTP delivery, pending recipient input, account recovery,
offline queue recovery, body index upgrades, thread boundaries, archive byte
round trips, schedule restart recovery, and rule account isolation.

All 35 Mail demo snapshots rendered. The compact workspace and tool views were
visually checked, including populated Scheduled and Imported Mail lists. These
renders do not prove physical input or macOS permission dialogs.

The website passed desktop and mobile browser checks with no horizontal
overflow, missing images, broken section anchors, or third-party resource
requests. Public Mail imagery uses invented demo data only.

The release build completed for arm64 and x86_64. The app and bundled runner
passed strict code-signature verification. Version 1.21.0, build 42, was
installed locally with the existing Apple Development identity. The installed
executable hash matches the release build. The previous app was retained in
InstallBackups. This local install is separate from the source-only public
release; no notarized binary is published.

After installation, all six configured accounts passed live IMAP and SMTP
sign-in checks. The diagnostic listed folders and read Inbox counts. It did
not send, move, delete, or mark messages read. Live delivery and cross-device
draft acceptance remain untested.

### Xcode 26 source-build correction

GitHub's Xcode 26 compiler timed out on the Mail sidebar in 1.21.0. Version
1.21.1 splits that view into smaller expressions. The full local suite again
passed with 1,184 tests, three skipped, zero failures, and all 35 demo renders
completed. The account sidebar retained its controls and layout.

The 1.21.1 universal build also passed strict signature verification. GitHub's
hosted compiler and tests are checked separately from these local results.
