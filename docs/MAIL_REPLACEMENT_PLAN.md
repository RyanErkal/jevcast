# Mail replacement plan

Implementation checkpoint: version 1.21.0 adds the six approved feature groups.
[Mail features](MAIL_FEATURES.md) records the implemented behavior and its limits.
The acceptance target below remains broader than offline implementation proof.

## Product target

Mail lives only in the launcher. Keep the sidebar, list, reader, composer, and
account recovery inside that panel. Do not add a separate mail window, a
resizable mail window, or independent compose windows.

The first acceptance target is Ryan's six configured accounts, with Apple Mail
closed. Provider connection, delivery, and cross-device behavior need live
acceptance. Offline tests and demo snapshots do not establish that acceptance.
Do not run live account tests, install, or drive the app without the user's
go-ahead for those checks.

## 1. Account reliability

The first implementation adds:

- Retryable OAuth provider outages and rate limits, while rejected credentials
  still stop background sign-in attempts.
- Mail-specific Keychain errors, separate from rejected account sign-in.
- Account connection details in the launcher's reader area, including the last
  successful sync and an explanation that cached counts can be stale.
- Reconnect and retry actions. Browser sign-in is owned by the account service
  so hiding the launcher does not cancel it. Cancellation remains explicit.
- Sidebar recovery for accounts that have no downloaded folders.

Remaining acceptance: determine the actual failure for each account; check
receiving and sending separately; exercise reconnect, refresh, sleep, restart,
and signed-app Keychain access. Review Google's consent/registration setup if
sign-ins expire repeatedly. A bundled public OAuth client needs provider review.

## 2. Reliable sync and offline use

Add selectable offline storage, background history download, full message-text
indexing, and visible download/search coverage. Keep a durable queue for read,
flag, archive, and move actions. Reconcile queued changes against current server
identities after reconnect. Verify Gmail labels, deduplication, folder mappings,
and counts across all accounts. Uncertain sends still require explicit review.

## 3. Reading and organisation in the launcher

Add conversation threads, recipient/date/attachment search filters, multiple
selection, bulk actions, and drag-and-drop filing. Keep keyboard navigation,
focus, accessibility, and compact layouts usable inside the existing panel.
Show full email addresses when short account names are ambiguous.

## 4. Composition and delivery

Add contact suggestions, recipient chips, aliases, and automatic signatures.
Complete cross-device draft editing, attachment preview/save, and message
printing. Keep all composition in the launcher. Preserve the existing rich-text
composer, Undo Send, durable drafts, and explicit review of uncertain delivery.
Verify account identity, attachments, draft replacement, and one Sent copy.

## 5. Everyday replacement features

Add rules, smart mailboxes, VIPs, account notification controls, quiet hours,
sender blocking, snooze, Send Later, folder management, and optional default
mail-app registration. State which actions need Jevcast running. A missed or
interrupted send must not silently resume. Preserve remote-content and AI
writing choices. Broader providers and encrypted mail need separate acceptance.

## 6. Import, recovery, and cutover

Provide explicit import/export for local-only mail and archives. Check message
counts and attachments, and preserve Apple Mail's source data. Exercise large
mailboxes and six concurrent accounts, network loss, expired sign-in, crashes,
disk failures, and interrupted sends. Run `swift test`, `scripts/build.sh`, and
offline demo snapshots. Then perform approved live checks against webmail and a
phone. The final target is a week of daily use with Apple Mail closed and no lost
drafts, missing messages, or duplicate sends.
