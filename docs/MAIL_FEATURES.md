# Mail in the launcher

Version 1.21.0 keeps reading, composition, account recovery, and mail tools inside
the launcher. Open Mail with Hyper–M or `inbox`. The ellipsis above the message
list opens Mail tools. Escape returns from a tool to the previous draft or list.

## Use and limits

| Feature | Behavior |
| --- | --- |
| Offline & Storage | Select recent mail, selected folders, or all history for each native account. Background work advances in batches. Folder coverage and errors remain visible. All history is complete only after the download finishes. |
| Search and filters | Local full-text search uses indexed bodies. Sender, recipient, date, account, folder, unread, flag, and attachment filters are available. Recipient and attachment results are a lower bound while bodies are missing. |
| Conversations | Provider thread IDs and downloaded Message-ID references group messages within one account. Similar subjects alone never merge messages. Missing thread headers leave separate rows. |
| Bulk actions | Select loaded messages with Command-click or Shift-click. Read, flag, archive, move, and Trash actions report partial failures. Undo uses the retained identities. Bulk Trash does not permanently delete. |
| Offline changes | Read and flag operations can replay after reconnect. Moves with an uncertain result wait for review. Account, folder, UIDVALIDITY, UID, and available Message-ID values are checked before replay. |
| Recipients | Chips validate addresses. Suggestions use local mail. Contacts access begins only after the user selects the Contacts option. |
| Aliases | Add only an address already authorized by the provider and explicitly confirm that authorization. The provider still decides whether to accept it. The account remains the credential and SMTP envelope owner. |
| Server drafts | Edit Draft imports a selected server draft with its attachments. Local and remote conflicts are kept. Saving and cleanup use exact server references; uncertain acknowledgements need review. |
| Rules | Enabled rules act on newly observed Inbox arrivals after startup. Existing mail requires Preview and Apply. Actions are read/unread, flag/unflag, or move to a folder in the same account. Rules cannot permanently delete. |
| Smart mailboxes and senders | Save predicates, preview matching downloaded messages, and open a result. VIPs show a star. Blocking creates an exact sender rule targeting the account's Junk folder. |
| Notifications | Off by default per account. Notices use the notch, support private previews and quiet hours, and suppress initial history and backfills. They require Jevcast running. |
| Snooze | Local to this Mac. Hides the message from Inbox and Unread until its return time. Other folders and other devices retain it. |
| Send Later | Saves the entire draft and attachments before leaving the composer. Requires Jevcast running and the Mac awake. Missed times wait for review. Interrupted or uncertain dispatches require a Sent check. Startup never resumes them. |
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

Folder creation/renaming, default mail-app registration, encrypted mail, and a
week-long cutover exercise are separate follow-up work. The features above do
not establish complete Apple Mail parity.

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
