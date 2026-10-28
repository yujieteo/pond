# pond
A fun, low-energy media and experiments companion: iOS app, signed log, stream on teoyujie.org/log

- `docs/concepts.md`: the conceptual model.
- `docs/protocol.md`: the signed save request and the server's replies.
- `PondKit/`: the Swift package for the app: entry format and signing, the plan parser, the host-to-domain guess, and "One paper".
- `server/`: the save service, in Goose, with the generated C beside it.

## Test

```
server/build.sh && server/test.sh
swift test --package-path PondKit
```

`server/test.sh` needs `openssl`. One PondKit test runs the built `server/pond_save`, so build the server first.
