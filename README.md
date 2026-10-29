# pond
A fun, low-energy media and experiments companion: iOS app, signed log, stream on teoyujie.org/log

- `docs/concepts.md`: the conceptual model.
- `docs/protocol.md`: the signed save request, the server's replies and the read side.
- `PondKit/`: the Swift package for the app: entry format and signing, the plan parser and editor, the plan commit through the GitHub API, the grid, the starter experiments, the host-to-domain guess, and "One paper".
- `server/`: the save service, the read service and `pond_node`, the daemon of the store with the sync between the nodes, in Goose, with the generated C beside them. `server/service/` has the service files of the daemon for OpenBSD, Linux and macOS.
- `store/`: the storage engine for the log, in Goose: one append-only segment file with a checksum for each record, and an index by id, date and tag. `docs/store.md` is the design. `pond_node` keeps the store in shadow mode beside the entry files of pond_save.
- `app/`: the iOS app, Waldenlog on the Home Screen: Today, the entry sheet, the phone key, the outbox, the plan editor, the grid and the experiments.
- `mac/pond-key/`: the Mac enrol key (R7 in `docs/concepts.md`): a command-line tool that makes a Secure Enclave key and signs request bodies.

## Test

```
server/build.sh && server/test.sh
python3 server/sync_test.py
store/build.sh && store/test.sh
swift test --package-path PondKit
swift test --package-path mac/pond-key
```

`server/test.sh` and `server/sync_test.py` need `openssl`. `server/sync_test.py` runs 3 nodes on this machine and tests the sync between them. `server/bench.sh` measures the read path of pond_read and of `pond_node`. Two PondKit tests and one pond-key test run the built `server/pond_save`, so build the server first.

## The Mac key

`pond-key` makes a P-256 key in the Secure Enclave of the Mac. The private key cannot leave the Mac.
The tool keeps only a handle to the key, in `~/Library/Application Support/pond-key/<name>.key`. The handle works on this Mac only.
Each signature needs Touch ID or the Mac password.

The Mac key is the enrol key only (R7 in `docs/concepts.md`). Never put it in `/var/www/pond/keys`: the server accepts entries from each key in that directory.
The signed `POST /pond/key` enrol request is a later task. Until then, use `pond-key sign` only for a smoke test against a local test server.

1. Build the tool and the server:

   ```
   swift build --package-path mac/pond-key -c release
   cp "$(swift build --package-path mac/pond-key -c release --show-bin-path)/pond-key" ~/bin/
   server/build.sh
   ```

2. Make the key. The name is the `key` id of `docs/protocol.md`: 1 to 64 of `A-Z a-z 0-9 -`.
   The tool writes the public key file to stdout, and its file name to stderr.

   ```
   pond-key create mac > mac.pub
   ```

3. Make a local test server directory, with the Mac key in its `keys/`:

   ```
   dir=$(mktemp -d) && mkdir "$dir/keys" "$dir/entries" && cp mac.pub "$dir/keys/mac.pub"
   ```

4. Sign one test entry and post it to the local server. The `key` field of the body must be the name of the key. `pond-key sign` reads that field, signs the exact bytes of the file, and prints the `Signature` header value.

   ```
   printf '%s' '{"entry":{"date":"2026-10-28","title":"a test entry"},"id":"mac-test","key":"mac","op":"put","rev":1,"v":1}' > body.json
   env -i REQUEST_METHOD=POST CONTENT_LENGTH=$(wc -c < body.json | tr -d ' ') POND_DIR="$dir" \
       HTTP_SIGNATURE="$(pond-key sign body.json)" server/pond_save < body.json
   ```

   The reply is `Status: 201` for a new entry. Delete the test directory after the test: `rm -r "$dir"`.

## The app

`app/Pond.xcodeproj` builds the iOS app. The Home Screen name is Waldenlog. The code, the bundle ID `org.teoyujie.pond` and the server paths keep the name pond.

- Today shows the menu (today's slot from the plan, one entry that you marked "good" or "loved it", one grid cell not visited yet this year), the "Every day" row and the entries of today.
- The phone keeps each entry in `journal.json` first. The outbox sends each change, signed, to `POST /pond/entry`, and sends a failed change again at the next change, when the app opens, or after a minute. After a 409, it sends the change again with the revision after the server's.
- The key is a P-256 key in the Secure Enclave, made at the first send or at "Show key". The simulator has no Secure Enclave, so it uses a software key.
- The plan is `media-plan.md` in the site repo `yujieteo/site`. The app loads it with the GitHub API when it opens. Before the first load, it uses the copy in the PondKit test fixtures.
- Plan (the plan editor) shows each slot of the menu with its 7 day buttons. Tap a slot to change its words, tap a day to add it or take it away, "+ Add a slot" to add one. A slot on other days than its list gets a marker at the end of its line, for example `(days: Mon Fri)`. Added slots go in the list "Added in the app". The weekday core is the "Every day" row, so it is not in the editor.
- Each change goes to the site repo as a commit 7 seconds after the last change, after the 6 seconds of "Undo". The commit needs a fine-grained GitHub token with "Contents: read and write" on the site repo only. Paste it under "GitHub token" in Plan. The app keeps it in the Keychain behind Face ID or the passcode. If the site copy changed after the phone loaded it, the app loads the site copy and the phone's change goes.
- Grid shows the 17 domains × 4 modes of the selected year. A filled dot is a cell with an entry. A tap on a dot shows its entries, or "Pick for today" for an empty cell of this year.
- Experiments has the starter set: 5 experiments from X1 to X8 of the design board, with credit and links. One runs at a time, for 7 days. While it runs, it is the last choice on Today, and "Done" on it counts a day and makes no entry. "Close" asks "What did you notice?" once: "Keep private" keeps the line on the phone, "Publish" makes an entry of kind note after the 6 seconds of "Undo".
- The invite is one notification a day at the invite time (⏰ on Today, 19:30 at first), with up to 4 choices as buttons. A pick changes the notification in place to the pick, "✓ Done" and "Something else", with no sound. "✓ Done" records the entry like "Done" on Today. An ignored notification stays until you clear it, and the next day removes it.
- The app computes the choices of the next 14 days when it schedules them, each time that it opens or that the journal changes. If the app does not open for 14 days, no notification comes after the 14th day.
- The Home Screen widget (medium or large) and the Lock Screen widget show the same choices or the same pick as the notification. Their buttons run in the app, with the same journal, key and outbox. "Done" on the Lock Screen asks for the unlock, because the Secure Enclave key needs it.
- The app writes the invite to `invite.json` in the App Group `group.org.teoyujie.pond`, and the widgets read it.

To enrol the phone, tap "Show key" and put the text in `/var/www/pond/keys/<name>.pub` on the server.

The launch argument `-server <url>` changes the save service from `https://teoyujie.org`, for example to a local test server.
`PondUITests` is the simulator proof. `ScreensTests` tests the plan editor, the grid and the experiments with no server: run it with `-only-testing:PondUITests/ScreensTests` and `TEST_RUNNER_POND_SHOTS` only. `testRecordOneEntry` enrols the key on a local test server, records one entry and waits until the server accepts it. `testInvite` sets the invite time to the next minute, picks the first choice in the notification, taps "✓ Done" in the Home Screen widget and waits for the entry on `/log/`. Before `testInvite`, add the medium Waldenlog widget to the Home Screen and to the Lock Screen by hand. The test cannot open a notification in the list for its buttons, so it taps "✓ Done" in the widget.
Run it against the built server programs:

```
dir=$(mktemp -d) && mkdir "$dir/keys" "$dir/entries" && python3 server/local.py "$dir" &
TEST_RUNNER_POND_KEYS="$dir/keys" TEST_RUNNER_POND_SHOTS=<screenshot dir> \
    xcodebuild test -project app/Pond.xcodeproj -scheme Pond -destination 'platform=iOS Simulator,name=iPhone 17'
curl http://127.0.0.1:8787/log/
```

## TestFlight

`scripts/testflight.sh` archives the app, uploads it to App Store Connect and waits until the build is in the TestFlight group "Captain". Run it on the Mac after each merge:

```
scripts/testflight.sh
```

The build number is the number of minutes since 1 January 2026 (UTC). To set a different number, use `BUILD=<number>`. The version comes from the project.
The script signs and uploads with the App Store Connect API key only. It reads `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID`, and has defaults for the Mac. The Mac must have the Apple Distribution certificate and the "Waldenlog App Store" profile.
The archive and the logs go into a temporary directory. The script stops after 60 minutes if processing is not complete.
