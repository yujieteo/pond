# pond
A fun, low-energy media and experiments companion: iOS app, signed log, stream on teoyujie.org/log

- `docs/concepts.md`: the conceptual model.
- `docs/protocol.md`: the signed save request and the server's replies.
- `PondKit/`: the Swift package for the app: entry format and signing, the plan parser, the host-to-domain guess, and "One paper".
- `server/`: the save service, in Goose, with the generated C beside it.
- `mac/pond-key/`: the Mac enrol key (R7 in `docs/concepts.md`): a command-line tool that makes a Secure Enclave key and signs request bodies.

## Test

```
server/build.sh && server/test.sh
swift test --package-path PondKit
swift test --package-path mac/pond-key
```

`server/test.sh` needs `openssl`. One PondKit test and one pond-key test run the built `server/pond_save`, so build the server first.

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
