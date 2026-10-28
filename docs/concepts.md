# Pond: conceptual model

Pond is a small iOS app that offers a short menu of media and experiments each day, and records what you did.
Each record is signed on the phone and goes to a public stream at teoyujie.org/log.
This file is phase 1 of the concept-ui method: concepts, objects, synchronisations and posture.
It has no layout, widgets, colours or screens. The design board has those.

## Requirements after step 1

Each requirement has a reason. The captain agreed each one in the grilling session of 2026-10-28, unless the line says otherwise.

| # | Requirement | Reason |
|---|---|---|
| R1 | The app records only what happened. It has no "skipped" state, no streak and no score. | The captain rejected shame as a motive ("not inline with Joe Hudson"). A missed day must leave no mark. |
| R2 | Each day the app offers a menu of 3 choices: today's slot, one thing enjoyed recently, one place not visited yet. An active experiment adds a 4th choice. | The captain wants choice, not duty. The menu replaces the checklist. |
| R3 | One notification each day at a time that the captain sets, "What do you want today?", with the choices as buttons. If the captain ignores it, nothing happens. | The captain forgets the plan. One notification stops the forgetting, and no follow-up stops the nagging. |
| R4 | An entry has date, slot, title, link, what I made, domain (1 to 17), mode (at home, live, take part, make) and interest. The entry sheet shows only the title. The other fields are under "More", and the app fills them. | The captain asked for full fields, then said the sheet was too wordy: "I won't fill in this" (board round 1). |
| R5 | A share-sheet entry fills title, link and domain from the shared page. | The captain finds most media in other apps. |
| R6 | The server accepts only entries signed by an enrolled device key. The key is in the phone's Secure Enclave. | Prevents a security fault: anybody can post to an open save service. |
| R7 | A second key, made on the Mac, enrols a new phone. | The Secure Enclave key cannot leave the phone. Without an enrol key, a new phone needs a server change. |
| R8 | The plan file `media-plan.md` is the master copy, in the site repo. The app edits it and commits through the GitHub API, with a token limited to the site repo, in the Keychain behind Face ID. | The captain asked for one master copy, and to update the plan in the app. The token scope prevents a security fault. |
| R9 | The yearly grid shows 17 domains × 4 modes. A filled cell shows where you have been. The app shows the empty cells only to the captain, as places not visited yet. | The plan needs a tick in each of the 68 cells each year. An empty cell is an invitation, not a failure. |
| R10 | Experiments are private. One "What did you notice?" line can be published by choice. | The captain asked for this. Inner work is not for an audience. |
| R11 | An optional private fun mark after each entry: a little, good, loved it. | It feeds the "enjoyed recently" choice, and it trains attention on what is fun (Joe Hudson: let pleasure land). |
| R12 | The public stream at teoyujie.org/log lists entries, newest first, with RSS. No posts to X. | The captain asked for microblog entries on the blog. |
| R13 | "Every day" items (for example RSS, textbook, fiction) show as one row of buttons on Today. A tap records the item. An item not tapped leaves no mark. | The captain: "I also have stuff that I want to read daily" (board round 1). |
| R14 | Interests are a list of topics (for example advanced packaging, math, aerospace structures, biology), each with its feeds and a hand list of classic papers. "One paper" offers a real paper from the feeds of the interest visited least lately, or a classic on the days that the captain marks "old". No interest has a quota. The captain sets the days of "One paper". The log shows the interest of a paper. | The captain has many uneven interests and "feels weird" with one paper a week (board round 1), and asked for "a solution for papers in various domains" (board round 3). |
| R15 | A live event is saved from the share sheet with its date, time and place. On that day it is the live choice, with time, travel time and cost, and "Go" opens directions in Maps. | The captain is reluctant to go to live events and wants them "pseudofrictionless" (board round 1). |
| R16 | A Home Screen widget and a Lock Screen widget show the invite, with the same pick and "Done". | The captain asked for a widget (board round 1). |

### Requirements deleted or changed in step 1 and step 2

- **"Enough, out loud" (X9)**. Deleted by the captain (board round 1).
- **Nine separate experiments**. Merged into five: the captain said they "boil down to feeling your feelings" (board round 1). One experiment, "Feel it fully", now has concrete activities to choose from.
- **Slots fixed to one weekday**. Changed: each slot shows on the days that the captain taps. The captain asked "Can I pick and choose or do I move it around?" (board round 1).

- **"Post on X, and keep a copy in a log page"** (media-plan.md, "One home"). Deleted: the captain said no posts to X. The plan file must change this line when it moves.
- **"On Sunday, check that the week's posts cover at least 4 domains"** (media-plan.md). Deleted from the app: it is a quota check, and quotas bring shame. The grid shows the spread without a target.
- **"At least one old source each week"** (media-plan.md). Not a rule in the app. It stays in the plan as text. The days marked "old" give a classic paper instead (R14).
- **A login or password for the save service.** Not added: the signature does the same check (R6).
- **Private data on a server.** Not added: fun marks, experiments and the "not visited" list stay on the phone. An iCloud device backup moves them to a new phone. Reason to keep it this way: no server copy of private data means no leak of private data.
- **A separate "pick" record.** Not stored: a pick is not something that happened. Only "done" makes an entry (R1).
- **An edit history of entries.** Not added: the server keeps the newest signed revision of each entry only.

## Concepts

### Plan
- **Purpose**: say what each day offers.
- **State**: the text of `media-plan.md`, its Git blob SHA, and the slots parsed from it. Each slot has text and its days: every day, or a set of weekdays.
- **Actions**: `load`, `editSlot`, `setDays`, `addSlot`, `removeSlot`, `commit`.
- **Operational principle**: after you tap Monday and Friday on "One paper, from an interest", the menu offers a paper on those days too, and the site repo has the change.

### Invite
- **Purpose**: remind you once a day that you can choose something fun.
- **State**: the invite time, and for each day its choices (at most 4) and its pick (at most 1).
- **Actions**: `setTime`, `offer`, `pick`, `unpick`.
- **Operational principle**: after you set the time to 19:30, a notification "What do you want today?" comes at 19:30 with the choices as buttons. If you tap none, nothing more occurs.

### Entry
- **Purpose**: record one thing that you did.
- **State**: id, revision, date, slot (optional), title, link (optional), made (optional), domain (optional for a note), mode, kind (media or note), device key id, signature, sent or waiting.
- **Actions**: `record`, `edit`, `remove`, `restore`.
- **Operational principle**: after you record "1987 - IEEE Standard on Piezoelectricity" with a link, it shows at the top of teoyujie.org/log and in the RSS feed. If you remove it, it goes from the stream.

### Fun
- **Purpose**: notice what you enjoy.
- **State**: for each entry, one level of three (a little, good, loved it), or none.
- **Actions**: `mark`, `clear`.
- **Operational principle**: after you mark an album "loved it", that album's kind of thing comes back as the "enjoyed recently" choice on a later day.

### Grid
- **Purpose**: show where you have been this year.
- **State**: none of its own. It counts entries for each of the 68 cells (17 domains × 4 modes) in the selected year.
- **Actions**: `selectYear`, `openCell`.
- **Operational principle**: after you record a live gig, the cell "Music × Live" fills. A cell with no entry is a place not visited yet, and only you see it.

### Experiment
- **Purpose**: try one small inner practice for a few days, and notice what changes.
- **State**: a library of experiments (title, steps in our own words, credit, source link, origin starter or shared), and at most one active run (start date, days, notice line, published or not).
- **Actions**: `add`, `start`, `close`, `publishNotice`, `remove`.
- **Operational principle**: after you start "Do it restfully" for 7 days, it is the 4th choice each day. When you close it, the app asks once "What did you notice?". You can leave the line empty, keep it private or publish it.

### Interest
- **Purpose**: spread "One paper" across many uneven interests, with no quota.
- **State**: a list of topics, and the weekdays marked "old". Each topic has 0..n sources (an arXiv category, or a journal RSS or Atom feed), a hand list of classic papers, and the date of its last entry. The set of papers already read.
- **Actions**: `add`, `rename`, `addFeed`, `removeFeed`, `addClassic`, `removeClassic`, `markOldDays`, `remove`.
- **Operational principle**: after you read a biology paper, the next "One paper" is the newest unread paper from the feeds of the topic that you read least lately, for example aerospace structures. On a day marked "old", it is the first unread classic of that topic. If that topic has no unread paper, the next topic gives one.
- **Where it runs**: the phone reads the feeds. The server has no part in it.

### Event
- **Purpose**: make a live event as easy as a video at home.
- **State**: title, date, time, place, cost, link.
- **Actions**: `save`, `edit`, `remove`, `go`.
- **Operational principle**: after you share an event page and tap "Save for that day", the event is the live choice on its day, with the travel time. "Go" opens the directions.

### Device key
- **Purpose**: prove that an entry comes from the captain.
- **State**: on the phone, a private key in the Secure Enclave. On the Mac, the enrol private key. On the server, the enrol public key and the list of enrolled device public keys.
- **Actions**: `sign`, `enrol`, `revoke`.
- **Operational principle**: after the Mac enrols the new phone's public key, the server accepts that phone's entries. An entry with no valid signature gets "403" and changes nothing.
- **First build**: `enrol` and `revoke` put or delete a key file on the server over SSH. The signed `enrol` request is a later task (docs/protocol.md).

### Stream
- **Purpose**: let other people follow what you do.
- **State**: none of its own. It shows the public entries, newest first.
- **Actions**: `read` (a visitor), `subscribe` (an RSS reader).
- **Operational principle**: after the server accepts an entry, the next request to /log or /log/feed.xml includes it.

## Objects (ORCA)

| Object | Relationships | Calls-to-action | Attributes |
|---|---|---|---|
| **Entry** | has 0..1 Slot; has 0..1 Fun mark; belongs to 1 Cell (a note has 0); comes from 0..1 Choice or from 1 share; signed by 1 Device key | record, edit, remove, undo, mark fun | date, slot, title, link, made, domain, mode, kind, sent or waiting |
| **Choice** | belongs to 1 Invite day; points to 1 Slot, 1 earlier Entry, 1 empty Cell or 1 Experiment | pick, unpick, done | label, source (slot, enjoyed, not visited, experiment) |
| **Slot** | belongs to 1 Plan; has 0..n Entries; has 1 domain and 1 mode | add, edit, set days, remove, undo | days (every day or some weekdays), text, domain, mode, minutes, what you make |
| **Plan** | has 1..n Slots; is 1 file in the site repo | edit, commit | file SHA, last commit, waiting changes |
| **Cell** | belongs to 1 Grid year; has 0..n Entries | open, pick (empty cell only) | domain, mode, count, examples from the Live column |
| **Experiment** | has 0..1 active run; has 0..1 Notice | add, open, edit, start, done today, close, remove, undo, publish notice | title, steps, credit, link, days, days done |
| **Notice** | belongs to 1 Experiment run; becomes 0..1 Entry of kind note | edit, publish, unpublish | text, private or public |
| **Fun mark** | belongs to 1 Entry | mark, clear | level |
| **Interest** | has 0..n Entries; has 0..n feeds | add, rename, add feed, remove feed, add classic, remove classic, remove, undo | name, feeds, classics, last visited |
| **Event** | becomes 0..1 Choice on its day; becomes 0..1 Entry | save, open, edit, remove, undo, go, done | title, date, time, place, cost, travel time, link |
| **Device key** | has 0..n Entries | show key, enrol (Mac), revoke (Mac) | name, key id, date enrolled |

## Synchronisations

1. When **Plan** `commit` succeeds, **Invite** `offer` makes the choices again for each day not yet offered.
2. When **Invite** `pick` occurs on a slot, enjoyed or not-visited choice, the notification changes in place to the pick and a "Done" button. No sound.
3. When the "Done" button is tapped, **Entry** `record` occurs with the fields of the picked Choice, then **Device key** `sign`, then the app sends it. With no network, the entry waits and the app sends it later.
4. When **Entry** `record` occurs, **Fun** offers `mark` once, in the same place, for 10 seconds. Ignored, it goes away.
5. When **Fun** `mark` is "loved it" or "good", that entry can become the "enjoyed recently" choice on a later day (at most once each 14 days).
6. When **Entry** `record` occurs, **Grid** counts it in its cell. If the cell was empty, it leaves the "not visited" list.
7. When **Experiment** `start` occurs, **Invite** `offer` adds it as the 4th choice for its days. "Done" on that choice counts a day of the run and makes no public entry.
8. When **Experiment** `close` occurs, the app asks "What did you notice?" once. When **Notice** `publish` occurs, **Entry** `record` makes an entry of kind note with that line, the experiment title and the credit link.
9. When **Entry** `remove` occurs, the entry goes from the screen at once. After 6 seconds with no `restore` (Undo), the app sends a signed removal, and **Stream** drops the entry.
10. When a share of a link occurs, **Entry** `record` uses the page title, the link and the domain from the host (for example youtube.com is 5, arxiv.org is 13). If the link is on artofaccomplishment.com, the share sheet also offers **Experiment** `add`.
11. When **Device key** `revoke` occurs on the Mac, the server refuses new entries from that key. It keeps the entries already accepted.
12. When **Event** `save` occurs, **Invite** `offer` uses it as the live choice on its date.
13. When **Entry** `record` occurs with an interest, **Interest** sets its last-visited date. **Invite** `offer` gives "One paper" the interest with the oldest date that has an unread paper: a feed paper, or a classic on a day marked "old".
14. When **Invite** `offer` or `pick` occurs, the widgets show the same choices or the same pick. "Done" in a widget is the same action as "Done" in the notification.
15. When a tap on an "every day" item occurs, **Entry** `record` occurs with that item. A second tap is `remove`, with no Undo toast, because the button itself shows the state.

## Modes

The four modes are the four columns of the plan's grid: at home (recorded), live (you attend), take part (you do it) and make (you make something from it). The plan calls the fourth column "Create (make)". The app uses "make". These four cover each way to meet a domain: alone or with people, as audience or as maker. A domain row with a missing mode is a place not visited yet.

## Posture

Pond is a **transient** app. You open it for less than one minute: pick, mark done, share a link, close an experiment. The widgets and the notification often replace the app.
The plan editor and the yearly review are longer visits, but they are rare (each week and each year).
So the chrome budget is the transient one: bars, panels and menus use at most 15% of the viewport height at 375 px width.

## Undo before send

A destructive action (remove an entry, a slot or an experiment, close an experiment, remove this phone) changes the screen at once and shows "Undo" for 6 seconds.
The app sends the signed request or the commit only after those 6 seconds. So "Undo" never needs the server, and no action needs a confirm dialog.

## Z-layers

One layer for each object kind. The Swift enum `Layer` and the CSS tokens of the mock-ups have the same values.

| Layer | Value | Objects |
|---|---|---|
| content | 0 | Entry, Choice, Slot, Cell, Experiment, Notice |
| controls | 1 | the floating control bar |
| sheet | 2 | entry sheet, cell sheet, share sheet |
| toast | 3 | undo toast, fun mark toast |

## Energy, fun and shame

Each concept keeps energy low, keeps fun high and avoids shame.

| Concept | Low energy | High fun | No shame |
|---|---|---|---|
| Invite | One notification, and the answer is one tap. | It asks what you want, not what you must do. | Ignored, it goes away. No "missed" mark, no second notification. |
| Entry | Only the title is necessary. One tap from the notification. | A find goes up at once, as in the "post as you go" style. | No streak, no count of days. |
| Fun | Optional, one tap, 10 seconds. | The app learns what you like and offers it again. | It is private. No level is wrong. |
| Grid | No upkeep. It counts entries. | Each filled cell is a place where you have been. | Empty cells are private, and they are invitations. |
| Experiment | One at a time, a few days, one optional line at the end. | Small trials, done with curiosity. | Private. No result is necessary. |
| Plan | Edit a slot in place. The commit is automatic. | You change the menu when it is not fun. | The plan is a menu, not a contract. |
