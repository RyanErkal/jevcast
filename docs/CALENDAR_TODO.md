# Calendar: morning checklist

Worktree: `/Users/ryanerkal/Dev/jevcast-calendar-20261006`  
Branch: `feat/google-calendar-20261006`  
Base: `aaf5a55` from `feat/mail-workspace`.

Added Google sign-in with read-only access, Week and Day time grids, clickable
event details, meeting notes, guests, linked documents, and Join Google Meet.

## Your checks

1. Quit the current Jevcast copy, then open `dist/Jevcast.app` in this worktree.
   Only one copy can run at a time.
2. In Calendar, click **Connect Google**. If needed, enable the Google Calendar
   API, add the Calendar read-only scope, and add your address as a test user in
   the Google project. The existing Mail desktop client can be reused.
3. Finish browser sign-in, then reopen Calendar. Check calendar selection, scrolling, event times, notes, linked
   documents, and **Join Google Meet** with a real event. Check typing and Escape.
4. Check Refresh and reopening Calendar. Review the existing scrolling test
   failure below before merging and installing.

## Verified locally

- **45 focused Calendar and OAuth checks pass.**
- Core offline suite: **543 tests, 3 skipped, 0 failures**. The skips need real
  user files or the real Trash. Initial full app runs passed; later full reruns
  hit the unchanged PanelScrollTests and one mail draft timing test.
- PanelScrollTests also fails on the original `aaf5a55` commit in a scratch
  worktree. The 12 mail draft coordinator tests pass in isolation on both versions.
- Fake Google responses cover OAuth scope, refresh, pagination, recurring events,
  all-day dates, time zones, notes, links, selection, and cancellation.
- Six demo snapshots inspected: Week, Day, Month, details, compact Week, sign-in.
- Universal arm64/x86_64 app and runner build: **passed**. Code signature: **passed**.

Live Google consent, account access, browser joins, physical input, and installed
app behavior remain unverified. No account was connected or changed by this task.
No app was installed or relaunched. Work remains in the separate worktree.

Evidence is in `dist/calendar-preview/`. See [Calendar development notes](DEVELOPMENT.md#calendar).
