# Native Mail

## Scope

Jevcast reads and sends mail in two ways. Jevcast accounts connect straight to
an account's IMAP and SMTP servers. The Apple Mail source reads Apple Mail's
index and makes changes through Apple Mail. You choose the source in Settings ›
Mail. Jevcast ships with no OAuth client: each user registers their own, as
described in Provider registration below.

## Acceptance

- Moves cannot expunge unrelated messages. Delete moves to Trash. In Trash,
  Delete removes the message for good, with one press. Empty Trash and
  Empty Junk remove exactly the counted messages after you confirm the count.
- Replies keep account identity, recipients, thread headers, and formatting.
- The composer has a sending account, rich text, and explicitly selected attachments.
- Drafts and send state survive restart. Uncertain sends are never retried automatically.
- Google and Microsoft public-client OAuth have PKCE, state checks, token refresh,
  Keychain storage, and an inspectable setup flow. Password accounts remain supported.
- Apple Mail actions verify message identity and preserve quoted rich text.
- Checks use `JEVCAST_MAIL_OFFLINE=1`, fake servers, and temporary stores.
- Run `swift test` and `scripts/build.sh`. Report UI renders separately from live proof.

## Implementation

Native accounts use IMAP and SMTP over TLS. The Apple Mail source remains a
separate choice in Settings. There is no automatic switch between sources when
an action fails. Queued sends and changes stop if their source changes.

- Account setup supports Yahoo, iCloud, Gmail, Outlook, and custom servers. IMAP
  and SMTP can have separate user names. The server must accept both sign-ins
  before the account is saved.
- Google and Microsoft sign-in use PKCE, a random state, a loopback callback, and
  fixed HTTPS token endpoints. Concurrent connections share a token refresh.
  Passwords, optional Google desktop secrets, and tokens stay in the Keychain.
- The composer works like Apple Mail's, inside the reading pane of the
  launcher panel's Mail view, not in a separate window. It has To, Cc, Bcc,
  Subject, and From fields, a signature button, and a formatting bar: font,
  size, palette colour, bold, italic, underline, strikethrough, alignment,
  lists, indent, link, image, and attachment. Default text has no colour, so
  it shows in the reader's own light or dark colour. It reads only files the
  user selects. Attachment bytes are kept with the draft. Limits are 30 files
  and 18 MB total.
- A reply shows the original below your text, read only, exactly as it is
  sent: "On 2 Oct 2026, at 03:01, Name <address> wrote:" and the original's
  HTML in a `type="cite"` quote with a blue bar. Remove Quote sends only your
  text. Its To and Cc are filled from Reply-To or the sender, and for Reply All
  from the others on To and Cc, without your addresses. Names stay. The fields
  are sent as you leave them. Native replies keep Message-ID references, quote
  styles scoped to the quote, and inline images. The original account is
  selected first. An explicit account change is permitted. The Message-ID uses
  the sending address's domain.
- A forward shows "Begin forwarded message:" with the original's From,
  Subject, Date, To, and Cc, then its HTML. Its attachments go one by one.
- A reply or forward sent during the undo time still goes when the original
  was archived or deleted meanwhile, from the copy kept with the draft. A
  forward whose attachments can no longer be read is refused, not sent without them.
- Drafts and send state live in the owner-only `MailComposition` folder. Each
  send state is saved before delivery. Recovery never resumes a send. An
  interrupted send is marked Uncertain and requires review before resend.
- Sync reads only what the mail view shows. The inbox gets its newest 500
  headers, and a folder gets its newest 200 the first time it is opened. A
  folder that was never opened is not read. Older mail is read 250 messages at
  a time, only when the list scrolls past the last message on this Mac. Bodies
  are downloaded when a message opens. The 30 newest inbox bodies up to 1 MB are
  read ahead.
- Searches cover UID ranges, never a whole folder, and each command stays
  inside the server's MESSAGELIMIT. Yahoo refuses a UID SEARCH that would find
  more than 1000 messages. A refused range is halved. CHANGEDSINCE is used only
  when the server offers CONDSTORE. Yahoo reports a mod-sequence without it.
- Moves use IMAP MOVE or UIDPLUS with a targeted UID EXPUNGE. A server with
  neither is refused before any copy or flag change. No mailbox-wide EXPUNGE or
  CLOSE exists. Delete moves to one selected Trash folder. A permanent delete
  names exact UIDs: UID STORE \Deleted, then UID EXPUNGE of the same UIDs, in
  batches inside MESSAGELIMIT. Other messages marked \Deleted stay. A server
  without UIDPLUS is refused before any change.
- The mailbox picker groups each account's mailboxes under its address, Inbox,
  Drafts, Sent, Junk, Trash, and Archive first. Counts come from the server
  (LIST-STATUS, or STATUS per mailbox) at most once a minute, so they include
  mail that is not on this Mac. Junk and Trash show how many messages they
  hold; other mailboxes show their unread count. Mark as Junk and Not Junk move
  a message to the account's one Junk mailbox or Inbox.
- Server folder roles are authoritative. Settings provides explicit Sent,
  Drafts, Archive, Trash, and Junk mappings. Missing or ambiguous roles stop the
  relevant operation. No folder is selected just because its name looks right.
- Apple Mail actions verify account, mailbox, index row, and Message-ID. Reply
  text is inserted into Mail's rich content object, so its quote is preserved.
  The Apple composer uses plain text for the added text. Failed composition
  closes only its outgoing object. Jevcast no longer automatically quits Mail,
  because Mail can be set to purge Trash on quit.

## Provider registration

Saving these settings does not connect a mailbox. No paid mail API key is needed.

### Google

1. Open [Google Auth Platform](https://console.cloud.google.com/auth/clients).
2. Configure the audience and consent screen. While the app is in Testing, add
   the account that will later sign in as a test user.
3. Create a client of type **Desktop app**.
4. Copy its client ID to Settings › Mail › Google and Microsoft Sign-In.
   If Google supplies a desktop client secret, enter it in the secure field.
5. Save Sign-In Setup. Then use Add Account and Google Sign-In.

IMAP and SMTP use the restricted `https://mail.google.com/` scope. While the
consent screen is in Testing, Google ends each sign-in after 7 days, so each
account needs Sign In Again once a week. For your own accounts (fewer than 100
people you know), you can publish the app to In production without Google's
verification. Google then shows an "unverified app" warning at sign-in, and
the sign-in no longer ends after 7 days. After publishing, sign in again once,
because a sign-in made in Testing still ends. A Gmail app password, with
2-Step Verification, is the other choice. Public distribution of one shared
client needs Google verification. See Google's [native app OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app)
and [Gmail OAuth guide](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol).

### Microsoft

1. Open [Microsoft Entra App Registrations](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade).
2. Register an app for organizational and personal Microsoft accounts.
3. Add **Mobile and desktop applications** with redirect URI
   `http://localhost/oauth/callback`. Microsoft ignores the dynamic loopback
   port when it matches this registration.
4. Add the **delegated** Office 365 Exchange Online permissions
   `IMAP.AccessAsUser.All` and `SMTP.Send`. Enable public client flows.
5. Copy the Application (client) ID to Settings › Mail. Do not create a client
   secret. Save Sign-In Setup.

The account's organization can block IMAP, SMTP AUTH, or consent. OAuth does not
override those settings. See Microsoft's [IMAP and SMTP OAuth guide](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth)
and [redirect URI rules](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).

## Support boundary

IMAP, SMTP, and provider OAuth are the standard direct connection path.
Apple Events use Mail's scripting dictionary, but reading the `Envelope Index`
uses Apple's private file layout. Apple does not provide a supported full inbox
API through that index. A macOS change can break the reader. MailKit is not a
general replacement for a complete mail client.

BuilderIO's `agent-native` was inspected for its Gmail OAuth and Jev design.
No code was copied. Its license metadata needs resolution before copying code.

The HTML cleaner and quote CSS parser cover passive email and common styles.
They are not a complete browser sanitizer or CSS parser. The reader also disables
JavaScript. Unsupported CSS nesting and rules that can target outside a quote
are omitted.

## Offline checks

```sh
JEVCAST_MAIL_OFFLINE=1 swift test
JEVCAST_MAIL_OFFLINE=1 scripts/build.sh
JEVCAST_MAIL_OFFLINE=1 dist/Jevcast.app/Contents/MacOS/JevLauncher --snapshot-ui /tmp/jevcast-mail-demo --demo
```

Offline mode refuses real IMAP/SMTP transport factories, OAuth requests, Mail
Apple Events, Mail launch, and access through the normal mail status reader.
Tests use fake transports and temporary stores. AppleScript checks compile the
scripts with `osacompile`; they do not execute them. Demo snapshots use invented
mail state. Build and demo layout proof do not prove a live provider connection,
permission prompt, real send, or Apple Mail rich-text insertion.

## Testing status

Offline tests cover the IMAP and SMTP protocol, sync, replies, forwards,
permanent deletes, Empty, and server counts. They run against fake IMAP and
SMTP servers that copy Yahoo's MESSAGELIMIT and UIDONLY behavior. Real Gmail
accounts with Google Sign-In and a Yahoo account with an app password have
synced and been read with this code. Sending, permanent delete, and Empty
were tested offline only. Microsoft sign-in has not been tried with a real
account. Apple Mail reply and forward through Mail's scripting are not proven.
