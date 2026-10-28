# pond
A fun, low-energy media and experiments companion: iOS app, signed log, stream on teoyujie.org/log

- `docs/concepts.md`: the conceptual model.
- `docs/protocol.md`: the signed save request, the server's replies and the read side.
- `PondKit/`: the Swift package for the app: entry format and signing, the plan parser, the host-to-domain guess, and "One paper".
- `server/`: the save service and the read service, in Goose, with the generated C beside them.
- `app/`: the iOS app, Waldenlog on the Home Screen: Today, the entry sheet, the phone key and the outbox.
- `mac/pond-key/`: the Mac enrol key (R7 in `docs/concepts.md`): a command-line tool that makes a Secure Enclave key and signs request bodies.

## Test

```
server/build.sh && server/test.sh
swift test --package-path PondKit
swift test --package-path mac/pond-key
```

`server/test.sh` needs `openssl`. Two PondKit tests and one pond-key test run the built `server/pond_save`, so build the server first.

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
- The plan is the copy of `media-plan.md` in the PondKit test fixtures, until the plan editor reads the site repo.

To enrol the phone, tap "Show key" and put the text in `/var/www/pond/keys/<name>.pub` on the server.

The launch argument `-server <url>` changes the save service from `https://teoyujie.org`, for example to a local test server.
`PondUITests` is the simulator proof: it enrols the key on a local test server, records one entry and waits until the server accepts it.
Run it against the built server programs:

```
dir=$(mktemp -d) && mkdir "$dir/keys" "$dir/entries" && python3 server/local.py "$dir" &
TEST_RUNNER_POND_KEYS="$dir/keys" TEST_RUNNER_POND_SHOTS=<screenshot dir> \
    xcodebuild test -project app/Pond.xcodeproj -scheme Pond -destination 'platform=iOS Simulator,name=iPhone 17'
curl http://127.0.0.1:8787/log/
```
