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

1. Build the tool:

   ```
   swift build --package-path mac/pond-key -c release
   cp "$(swift build --package-path mac/pond-key -c release --show-bin-path)/pond-key" ~/bin/
   ```

2. Make the key. The name is the `key` id of `docs/protocol.md`: 1 to 64 of `A-Z a-z 0-9 -`.
   The tool writes the server's key file to stdout, and the server file name to stderr.

   ```
   pond-key create mac > mac.pub
   ```

3. Copy the key file to the server by hand. The server then accepts entries that this key signs.

   ```
   scp mac.pub <server>:/var/www/pond/keys/mac.pub
   ```

4. Post one test entry. The `key` field of the body must be the name of the key. `pond-key sign` reads that field, signs the exact bytes of the file, and prints the `Signature` header value.

   ```
   printf '%s' '{"entry":{"date":"2026-10-28","title":"a test entry"},"id":"mac-test","key":"mac","op":"put","rev":1,"v":1}' > body.json
   curl -i https://teoyujie.org/pond/entry -H 'Content-Type: application/json' \
       -H "Signature: $(pond-key sign body.json)" --data-binary @body.json
   ```

   The reply is `201` for a new entry. Send the body again: the reply is `200`. To remove the test entry, sign and post `{"id":"mac-test","key":"mac","op":"remove","rev":2,"v":1}`.

To revoke the key, delete `/var/www/pond/keys/mac.pub` on the server.
