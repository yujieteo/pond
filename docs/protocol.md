# Pond: save protocol

The phone sends each change to an entry to the server as one signed request.
The server keeps the newest revision of each entry, and nothing else.
`server/pond_save.goose` is the server side. `PondKit/Sources/PondKit/Entry.swift` is the phone side.

## The request

```
POST /pond/entry
Content-Type: application/json
Signature: <base64 of the DER ECDSA P-256 SHA-256 signature of the body bytes>

{"entry":{"date":"2026-10-28","domain":15,"kind":"media","link":"https://example.org/std","mode":"home","title":"1987 - IEEE Standard on Piezoelectricity"},"id":"e1","key":"phone","op":"put","rev":1,"v":1}
```

| Field | Value |
|---|---|
| `v` | 1. |
| `op` | `put` (with `entry`) or `remove` (with no `entry`). |
| `id` | The entry id: 1 to 64 of `A-Z a-z 0-9 -`. The phone makes it. |
| `rev` | The revision, 1 or more. Each change to an entry has a higher `rev` than the change before it. |
| `key` | The id of the device key that signed the body: 1 to 64 of `A-Z a-z 0-9 -`. |
| `entry` | The public fields: the strings `date` and `title`, and the optional `link`, `made`, `domain` (1 to 17), `mode` (`home`, `live`, `take-part`, `make`), `kind` (`media` or `note`), `slot` and `interest`. `link`, `made`, `slot` and `interest` are strings. |

The signature is over the exact body bytes, so the server does not parse the JSON again to check it.
The phone sends the body as PondKit encodes it, with sorted keys.

## The replies

| Status | When | What changes |
|---|---|---|
| 201 | The signature is good and `rev` is higher than the saved `rev`, or the entry is new. | The server saves the body as the entry. |
| 200 | The body is the same as the saved body: a retry or a replay. | Nothing. |
| 400 | The body is not a valid request, or `entry` has a field that is not a public field, or a public field has a value that is not valid. | Nothing. |
| 403 | The signature is missing or bad, or `key` is not enrolled. | Nothing. |
| 405 | The method is not POST. | Nothing. |
| 409 | `rev` is not higher than the saved `rev`. The reply names the saved `rev`. | Nothing. |
| 411 | No `Content-Length`. | Nothing. |
| 413 | The body is more than 8192 bytes. The server does not read it. | Nothing. |

A replay of an old request gets 200 or 409, so it cannot bring an old revision back.
A `remove` is saved as the newest revision, so a replay of an older `put` cannot bring a removed entry back.
The server refuses an entry with a field that is not in the list of public fields, for example `fun`. Reason: a fault in the phone must not put private data in a public file.
The server holds an exclusive lock on `entries/.lock` from the `rev` check to the write. Reason: two requests at the same time must not let a lower `rev` replace a higher `rev`.

## The files

The data directory is `/var/www/pond/`. That is `/pond/` in the httpd chroot. The `POND_DIR` variable changes it for the tests.

| File | What it holds |
|---|---|
| `keys/<key>.pub` | One enrolled device key: base64 of its SubjectPublicKeyInfo DER, as CryptoKit's `derRepresentation` writes it. |
| `entries/<id>.json` | The newest accepted body of entry `<id>`, byte for byte. The write is atomic. |
| `entries/.lock` | An empty file for the lock. No id can have this name, because an id has no `.`. |

The server needs write access to `entries/` only.

To enrol a phone, put its public key in `keys/`. To revoke it, delete its file.
The server then refuses new changes signed by that key, and keeps the entries that it saved before.
The design has a signed `POST /pond/key` from the Mac enrol key (R7 in `docs/concepts.md`). A later task adds it. Until then, the Mac copies the key file over SSH.

## The program

The server is one CGI program under httpd and slowcgi. Goose compiles `pond_save.goose` to standalone C on the Mac, and the C is in the repository beside it.
The C needs only a C compiler and libcrypto, so it builds static on OpenBSD and runs in the chroot.
`pond_verify.h` and `pond_lock.h` are the only C that is not generated. `pond_verify.h` checks the signature with the EVP calls of libcrypto, which are the same in LibreSSL and OpenSSL. `pond_lock.h` locks with `flock`.

```
server/build.sh c   # on the Mac, with GOOSE=<path to goose>: make pond_save.c again, then build
server/build.sh     # build from the committed C
server/test.sh      # run the built program against this protocol
```

The OpenBSD build, the httpd and slowcgi lines and the proof in the chroot are a later task.
