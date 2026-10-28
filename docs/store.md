# Pond: the store

The store is the storage engine for the entries of the log. It replaces one file for each entry with one append-only segment file.
`store/store.goose` is the engine, and `store/store_io.h` has the few file calls that Goose does not have.
Phase 1 of 5 is the engine on one node. Phase 2 is the daemon `pond_node` in shadow mode: see [The daemon](#the-daemon). Phase 3 is the sync between the 3 nodes: see [Sync](#sync).

The store keeps the rules of `docs/protocol.md`:

- The higher `rev` wins. The same body again changes nothing. Any other body with a `rev` that is not higher is refused, and the reply names the saved `rev`.
- A `remove` is the newest revision of its entry. Thus a replay of an older `put` cannot bring the entry back.
- Each stored body is byte for byte the signed request body. The store does not change or encode it again. Reason: the signature is over the exact bytes, so a peer can check it again.
- A write holds an exclusive lock from the `rev` check to the end of the write. Reason: two writes at the same time must not let a lower `rev` replace a higher `rev`.

## The API

| Call | What it does |
|---|---|
| `store::open(dir, write)` | Opens `dir/store.seg`. A writer makes the files if they are not there, and recovers after a crash (see [Recovery](#recovery)). A reader changes no file. |
| `store::append(body)` | Saves a body with the rule above. The result is `Created`, `Same`, `Conflict` (with the saved `rev`), `Invalid` or `Failed`. `Created` comes back only after the record is on the disk. |
| `store::append_signed(body, sig)` | The same, and the record keeps `sig`, the base64 phone signature of the body. `store::signature(e)` gives it back. |
| `store::merge(body, sig)` | `append_signed` for a body from a peer, with the rule of a merge: at the same `rev`, the body that sorts later byte by byte wins (see [The rule of a merge](#the-rule-of-a-merge)). |
| `store::record(e)` and `store::each_in(bytes)` | The whole record of an entry, as the segment has it, and the signature and body of each record in bytes from a peer. |
| `store::get(id)` | The newest revision of the entry, a `put` or a `remove`, or null. `store::body(e)` gives its exact bytes. |
| `store::newest_first()` | The entries that are not removed: the later `date` first, then on the same date the later change. |
| `store::with_tag(t)` | The same list, with only the entries whose tag is `t`. The tag of an entry is its `interest`. |
| `store::refresh()` | Reads the records that other processes and threads appended after the last call. |
| `store::compact()` | Writes a new segment with only the newest revision of each entry (see [Compaction](#compaction)). |

The engine accepts a body if it has an `id` (a name of `docs/protocol.md`), a `rev` of 1 or more, and `op` `put` with an `entry` that has a string `date`, or `op` `remove` with no `entry`.
The engine does not check the signature or the public fields. pond_save does that before it saves.

The state of the store is in globals, so a process has one store open at a time.
Each Goose thread gets its own copy of the globals, so each thread can open the store on its own.
Many processes and threads can open the same store. Each write locks `store.lock` with `flock`, and reads the records of the other writers first.

## The record format

The segment is a sequence of records. Each record is a header of 12 bytes, then the payload:

| Bytes | Field |
|---|---|
| 0 to 3 | The magic `FF 50 4E 44` (`0xFF` and `PND`). |
| 4 to 7 | The length of the payload, u32, little-endian: 1 to 8448. |
| 8 to 11 | The checksum: CRC-32C of bytes 4 to 7 and of the payload, u32, little-endian. |
| 12 to the end | The payload: the body, or the phone signature of the body in base64 (1 to 255 bytes), a newline and the body. The body is the exact bytes of the signed request, 1 to 8192 bytes. |

A body starts with `{` or a space, and a signature starts with a base64 character. Thus the first byte tells if the payload has a signature.
The daemon saves the signature with each body. Reason: a peer checks the phone signature of each body that it gets (see [Sync](#sync)).
The checksum also covers the length. Thus a changed length cannot make the store read a wrong body.
The magic starts with `0xFF`. That byte is not in UTF-8 text, so the magic is not in a JSON body of the phone.
The record has no `id` or `rev` of its own. The store reads them from the body, so each fact has one place.

## The checksum

The checksum is CRC-32C (Castagnoli), as in ext4, Btrfs and iSCSI.
It finds all errors of 1 to 3 bits, and all bursts of errors up to 32 bits, in a record of 8 KB or less. It finds other errors with a probability of 1 - 2^-32.
CRC-32C finds more errors in short records than the CRC-32 of zip.
The checksum finds damage. It is not a security check: the phone signature does that.
`store.goose` calculates the CRC with a table of 256 values, so it needs no C.

## The index

The index is in memory. The store makes it when it opens the segment, and changes it with each record.

- **By id**: a dictionary from the `id` to one item. The item has the newest `rev`, the place of the body in the segment, the number of the record (the order of the changes), the date, the tag, and a flag for a `remove`.
- **By date**: a list of the entries that are not removed, sorted by the date and then by the number of the record. The store sorts the list again only after a change.
- **By tag**: a list of the entries that are not removed and have a tag, sorted by the tag, then in the order of the date list. `with_tag` finds the entries of one tag with a binary search. The store sorts this list again with the date list.

The date and the tag are kept with their JSON escapes decoded, so `"biology"` has the tag `biology`.

The store also keeps the bytes of the segment in memory, so a read does not go to the disk.
A Goose data stack holds the segment. `store/build.sh` sets 16 MB for each stack, which holds about 50,000 entries. A larger log needs a larger stack, or a compaction.

## Writes

`append` does these steps:

1. It reads the body and refuses it with `Invalid` if the body does not have the fields above. It copies the body.
2. It locks `store.lock`.
3. It reads the records that other writers appended since its last read. If the file has a torn record at the end, it cuts that record off the file. If the file has damage at the end, the result is `Failed`.
4. It applies the rule. If the body is the same as the newest body, the result is `Same`. If the `rev` is not higher, the result is `Conflict`.
5. It writes the record at the end of the file with one `write`, then calls `fsync`. On macOS it calls `fcntl(F_FULLFSYNC)`, because `fsync` on macOS does not empty the cache of the disk.
6. It adds the record to the index, and releases the lock.

If the write or the `fsync` fails, the store cuts the file back to the end of the last good record, and the result is `Failed`.
The writer `open` also calls `fsync` on the directory. Thus the name of a new segment is on the disk.

## Recovery

`open` and `refresh` read the segment from the end of the last good record. A record is good if it has the magic, a length of 1 to 8448, all of its bytes, and a good checksum.

| What the store finds | What it does |
|---|---|
| A good record. | It adds the record to the index. |
| Bytes that are not a good record, and no good record after them, with no magic, a length that is not 1 to 8448, or fewer bytes than their length: a torn record from a crash in the middle of a write, or zeros from the file system. | A reader does not serve the bytes, and does not change the file. A writer, which holds the lock, cuts the bytes off the file before it appends. |
| Bytes that are not a good record, and no good record after them, with the magic, a length of 1 to 8448 and all of the bytes: damage in the last record. | The store does not serve the bytes, and adds them to the damage list. No write cuts the damage, each `append` gives `Failed`, and `compact` refuses to run. |
| Bytes that are not a good record, and a good record after them: damage in the middle. | The store does not serve the bytes, and adds them to the damage list. It reads the records after them as usual. No write cuts the damage, and `compact` refuses to run. |

A write gives the bytes of a record in sequence, so a crash in the middle of a write leaves fewer bytes than the length. Thus a record with all of its bytes and a bad checksum is damage to an acknowledged record, not a torn write.
A change in the magic of the last record makes it look like a torn record. A change in its length to a value that is not 1 to 8448, or past the end of the file, does the same. The writer cuts it.
The writer refuses to append after damage at the end. Reason: an append after it hides the damaged record from the operator, and the bytes of the damage stay for a repair.

A reader that reads while a writer writes can see a part of a record at the end. That part is a torn record to the reader, so the reader does not serve it. It reads the whole record at its next `refresh`.

Damage loses the record that it hits on this node. The store does not serve a changed body, and it serves all the other records.
If the lost record was the newest revision of its entry, `get` gives the revision before it until a repair.
The sync pulls that revision from a peer again, and appends it after the damage in the middle. Damage at the end stops all appends, also of the sync, so the damage list tells the operator.
`compact` refuses to run on a store with damage. Reason: the old bytes can help a manual repair, and a compaction removes them.

## Compaction

`compact` writes the newest record of each entry, a `remove` too, to `store.seg.new`, in the order of the changes. Then it calls `fsync` on the new file, renames it to `store.seg`, and calls `fsync` on the directory.
A crash at any point leaves the old segment or the new one at `store.seg`. Each one has all the newest revisions.
A leftover `store.seg.new` from a crash does no harm. The next compaction makes it again from empty.
Other processes see the new inode at `store.seg` at their next read, and read the new segment from the start.
A reader that has the old segment open keeps its old file until then.

## Tests

```
store/build.sh c   # on the Mac, with GOOSE=<path to goose>: make the C again, then build
store/build.sh     # build from the committed C
store/test.sh      # run all the tests below
```

The build makes `store/store_test` and `store/store_tool` with `-DSTORE_FAULTS`.
With that flag, the variable `STORE_CRASH_AFTER=<n>` kills the process with SIGKILL when its writes reach `n` bytes. The kill can occur in the middle of a record. These two programs are for the tests only.

`store_test` runs in one process:

- **The rules**: create, the same body, a different body at the same `rev`, a higher `rev`, a replay of an old `rev`, a `remove`, a replay after a `remove`, 8 bodies that are not valid, and a body over 8192 bytes.
- **The index**: the order by date and change, the list by tag with escapes, a change of tag, a removed entry, a change that moves an entry up, and a reader that opens the same store.
- **Torn records**: a cut of a segment of 12 records at each byte (1,323 cuts). After each cut, a reader serves only the whole records, and a writer cuts the torn bytes off and appends. It also adds tails of zeros and of random bytes.
- **Damage**: 2,000 trials that change 1 byte or a run of 1 to 64 bytes in a segment of 40 records. After each trial, the store serves all the records that the damage did not hit, serves no changed body, reports the damage, does not cut it, and refuses to compact. A change of 1 byte in the body of the last record is also damage: the writer reports it, does not cut it, and refuses to append. Zeros in place of the last record are a torn record: the writer cuts them off and appends.
- **Signed records and merges**: a signature is kept beside its body and stays after a compaction. A merge at the same `rev` takes the body that sorts later and refuses the other. A merge of the same body with another signature changes nothing. A changed byte in records from a peer is found.
- **Compaction**: 201 records of 7 entries become 7 records. The newest bodies, the order and the rule stay the same, and a reader sees the new segment.
- **Threads**: 8 writer threads make 150 appends each to 10 entries. Each writer uses the `rev` after the one that it saw last, as the outbox of the phone does after a 409. 2 reader threads call `refresh` at the same time and check what they see.

`test.sh` then runs the tests that need processes. After each kill, `store_tool verify` compares the store with a model of the rule. The model gets the lines that the writer acknowledged, and the line that was in flight at the kill.

- **1,000 kills at random points**: each kill is at a random byte from 1 to 600 of the writes, so most kills occur in the middle of a record. Each 25th pass is a compaction.
- **100 kills at a random time**: SIGKILL from outside, 1 to 60 ms after the writer starts.
- **6 writer processes** on one store, with the same rule as the writer threads.

A kill counts only if the process died by SIGKILL. A pass in which the process ends before its kill point does not count. The test runs until it has 1,000 kills and 100 kills.

After each kill, the test checks these points:

- No acknowledged line is lost or changed.
- Each record in the segment is one whole line of the input.
- No `rev` of an entry goes back in the segment.
- The segment has no damage.

A kill does not lose the data that the kernel has in its cache. Thus the kill tests show the recovery after a crash of the process. The cuts at each byte show the recovery after a power loss in the middle of a write.

## Measured results

All the tests pass on these three systems. The numbers are from `store_test` and `test.sh` on 2026-10-28.

| | macOS (Mac, APFS) | Linux (NixOS desktop) | OpenBSD 8.0 (VM on the desktop) |
|---|---|---|---|
| All of `test.sh` | 161 s | 27 s | 22 s |
| An append, with the `fsync` (2,000 appends) | 4,963 µs | 1,028 µs | 91 µs |
| An open of 2,000 records | 2,094 µs | 800 µs | 1,324 µs |
| A `refresh` and a walk of the list of 2,000 records | 9 µs | 2 µs | 2 µs |
| 8 writer threads, 1,200 appends | 4.5 s | 1.0 s | 5.0 s |

| Test | Result on each system |
|---|---|
| Kills at random points in a write | 1,000 by SIGKILL in 1,009 passes (31 in a compaction): 0 lost or changed lines, 0 parts of a record served |
| Kills at a random time | 100: 0 lost or changed lines |
| Cuts at each byte | 1,323: 0 faults |
| Damage in the middle | 2,000 trials: 0 faults |
| Writer threads and processes | 0 `rev` that goes back, 0 lost changes |

The time of an append is the time of the `fsync`. On macOS, `F_FULLFSYNC` waits for the disk itself, so it is the slowest.
The VM does not wait for the disk of the desktop, so its `fsync` is fast. The real server will be slower.
To check that the crash tests find faults, a test build had no cut of the torn record. The verify found damage after the second kill.

## The daemon

`server/pond_node` is a daemon that runs all the time on each node. It keeps the store, and it serves the read path from the store.
Phase 2 runs it in shadow mode: pond_save and the entry files stay the source of truth (see [Shadow mode](#shadow-mode)).
The daemon is the same Goose program on OpenBSD, Linux and macOS. `server/pond_net.h` has its socket calls in C.

```
pond_node --pond <dir> --store <dir> --template <file> --port <n> [--wireguard <address>]
```

| Option | What it is |
|---|---|
| `--pond` | The directory of pond_save, with `entries/` and `keys/`. The daemon only reads it. |
| `--store` | The directory of the store. The daemon makes it if it is not there. |
| `--template` | The page template of `/log/`, the same file that pond_read uses. |
| `--port` | The TCP port on 127.0.0.1. Port 0 lets the system choose, for the tests. |
| `--wireguard` | The WireGuard address of the node. The daemon listens on it with the same port. |
| `--node` | The name of this node, for example `server`. The peers check its sync requests with `nodes/<name>.pub`. |
| `--node-key` | The private node key of this node, P-256 in PEM. The daemon reads it at the start, before the sandbox. |
| `--peer` | `<numeric address>:<port>` of a peer, on the WireGuard network: 1 to 8 times. It needs `--node` and `--node-key`. With no `--peer`, the node does not sync. |

### Threads

The threads share no data. They send work to each other on typed Goose queues, and each thread has its own copy of the globals of the store.

| Thread | Number | What it does |
|---|---|---|
| The acceptor | 1 | It waits for connections on 127.0.0.1 and on the WireGuard address, and puts each connection on the queue of the readers. If 1,024 connections wait on the queue, it closes the new connection. |
| The readers | The number of CPU threads, 2 or more | Each reader takes a connection from the queue, reads one request, sends the reply and closes the connection. Each reader opens the store as a reader. It makes the list of the log again only when the store changed. |
| The writer | 1 | It scans `entries/` each second, and appends each new body to the store. Between two scans, it merges the bodies that the syncer pulled. It is the only thread that writes. |
| The syncer | 1, with `--peer` | Each 5 s, it pulls from each peer the revisions that this store does not have, checks their phone signatures, and puts them on the queue of the writer (see [Sync](#sync)). |

At the start, the main thread opens the store as a writer and imports all the entry files. It listens before the import, but it starts the readers only after the import. Thus the daemon never serves a part of the log.

### Requests

The daemon reads one request on each connection, and closes the connection after the reply.

- The daemon speaks only FastCGI. httpd and the peers send this.
- If a request is not FastCGI, the daemon closes the connection with no reply.

The daemon serves `GET /pond/entries.json`, `/log`, `/log/` and `/log/feed.xml`.
It also serves `POST /pond/sync` to the peers (see [Sync](#sync)), and `GET /pond/node`: `{"entries":<n>,"hash":"<index hash>"}`. httpd does not send these two paths.
Each reply has the same bytes as the reply of pond_read, because both programs use the same code in `server/render.goose`.
Each other path gets 404, and each other method gets 405, as from pond_read.
A request can have 64 KB or less. Each read and each write on a connection has a time limit of 5 s. Reason: a slow client must not hold a reader.

### Where the daemon listens

- The daemon listens on 127.0.0.1, and on the `--wireguard` address if it is given. It listens on no other address.
- The `--wireguard` address must be a numeric address. The daemon refuses 0.0.0.0 and `::`, and stops. Reason: a mistake in the flags must not open the daemon on a public address.
- httpd sends the public requests to the daemon on 127.0.0.1. The peers connect on the WireGuard address.

### Limits on each system

| System | The limits |
|---|---|
| OpenBSD | Before the threads start, the daemon calls `unveil` on `entries/`, `keys/` and `nodes/` (read), the store (read, write and create) and the template (read). Then it calls `pledge("stdio rpath wpath cpath flock inet")`. `server/pond_node.h` has this code. rc.d runs the daemon as the user `_pondnode`. |
| Linux | The systemd unit `server/service/pond-node.service` gives a dynamic user, a read-only file system other than the store, a filter of system calls, and IPv4 and IPv6 sockets only. `systemd-analyze security` gives 1.2 ("OK"). |
| macOS | The launchd agent `server/service/org.teoyujie.pond-node.plist` runs the daemon as the user of the Mac. macOS has no `pledge`, so the Mac has the weakest limits. |

## Shadow mode

In phase 2, pond_save continues to write the entry files, and pond_read continues to serve the public site.
The daemon imports the entry files into the store, and serves the same pages beside pond_read. Nobody reads the pages of the daemon yet.
The compare tool finds each difference. After 3 weeks with zero differences, phase 5 makes the store the source of truth.

### The import

pond_save now writes the signature of each body to `entries/<id>.sig`, before it writes the body. Reason: the daemon checks the phone signature of each body that it imports.
The signature goes first. Thus a body on the disk has its own signature, or the signature of the next body for a short time. The daemon refuses the body in that time, and takes the next body at the next scan.

The writer scans `entries/` each second. It takes each `.json` file whose time or `.sig` time changed since the last scan. For each file, it does these steps:

1. If the store has the same body as the newest revision, it does nothing.
2. It checks the signature with the key in `keys/` that the body names. If the signature is not good, it refuses the body.
3. It appends the body to the store, with its signature, with the rule of the store: the higher `rev` wins.

The log of the daemon has a line for each change:

| Log line | Cause |
|---|---|
| `took <id>.json` | The store has the body now. |
| `refused <id>.json: no good signature from a key in keys/` | The file has no `.sig` file, a bad signature, or a key that is not in `keys/` now. |
| `refused <id>.json: the store has rev <n>` | The store has a higher `rev`. |
| `refused <id>.json: not a valid body` | The body does not have the fields of the store. |
| `cannot save <id>.json in the store` | The append failed. The writer tries again at the next scan. |

A refused file stays a difference between pond_read and the daemon, so the compare tool reports it.
pond_save is not on the server yet, so each entry on the server will have its `.sig` file. An entry file that a person adds by hand has no `.sig` file, and the daemon refuses it.
If an operator removes a key from `keys/`, pond_read continues to serve the old entries of that key, but the daemon does not import a new body of that key.
The protocol removes an entry with a `remove` body, not with a delete of the file. If a person deletes an entry file, the store keeps the entry, and the compare tool reports it.

### The order of the entries

pond_read lists the entries of one date in the order of the times of their files, the newest first. The store lists them in the order of its records.
Thus the writer takes the changed files of one scan in the order of their times. Then the two lists have the same order.
On OpenBSD, a file time has the resolution of a clock tick (about 10 ms), so two files can have the same time. pond_read then lists them in the order of their names. The writer takes files with the same time in the reverse order of their names, so the daemon lists them in the same order.

### The compare tool

`server/pond_shadow` compares the daemon with pond_read:

```
pond_shadow compare <pond_read> <pond dir> <template> <port>
```

- It runs pond_read as slowcgi does, for each of the 4 paths.
- It gets the same paths from the daemon on 127.0.0.1 over FastCGI.
- It compares the bytes. For `entries.json`, it reports each entry that differs: an entry that only one side has, a different `rev`, different fields, or a different order. For the other pages, it reports the first line that differs.
- The writer scans each second, so the tool tries a difference again after 2.5 s before it reports it.
- It prints `no difference`, or one line for each difference. The exit status is 0 for no difference, 1 for a difference, and 2 if it cannot run.

On the server, run the tool each hour as `_pondnode`. Add this line with `crontab -u _pondnode -e`:

```
0 * * * * (date -u; /usr/local/bin/pond_shadow compare /var/www/cgi-bin/pond_read /var/www/pond /var/www/web/site/log/template.html 8788) >> /var/pond-node/compare.log 2>&1
```

Each run writes the date, then the result. This command prints nothing if no run found a difference: `grep -v -e '^no difference$' -e UTC /var/pond-node/compare.log`.
Phase 5 starts after 3 weeks of hourly runs with only `no difference` lines.

`pond_shadow` also has the commands `get` (one request) and `bench` (see [Measured results of the daemon](#measured-results-of-the-daemon)).
With `fcgi`, these commands talk to the daemon. With `http`, they talk to an HTTP server, for a measure through httpd.

## Sync

Phase 3 makes a full copy of the store on each of the 3 nodes: the server, the desktop and the Mac. The sync is leaderless anti-entropy, with no consensus and no clock.

- Each node pulls from each peer, each 5 s, the revisions that it does not have. No node pushes.
- Each node checks the phone signature of each body that it pulls, with its own `keys/`. It refuses a body with no good signature.
- The highest `rev` of an entry wins. At the same `rev`, the body that sorts later byte by byte wins.
- Each sync request has a signature from the node key of the node that asks. A node refuses a request with no good signature from a key in its `nodes/`.

### A pull

The syncer of node A does these steps for each peer B:

1. It sends `index`, its name and its index hash. If B has the same hash, B replies with only its hash, and the pull stops.
2. Else B replies with its hash, then `<id> <rev> <crc>` for each entry, in the order of its changes. `crc` is the CRC-32C of the body.
3. A asks for each id where B has a higher `rev`, or the same `rev` with another `crc`, 100 ids in each request: `bodies`, its name, then the ids.
4. B replies with the record of the newest revision of each id, as its segment has it: the header with the checksum, the signature and the body. A checks the checksum of each record.
5. A checks the phone signature of each body. The syncer puts each good body on the queue of the writer, and waits until the writer merged the batch.
6. The writer merges each body with `store::merge`, between two scans of `entries/`.

A body with no good phone signature stays on B. A logs `refused <id> rev <n> from <peer>: no good signature from a key in keys/` one time, and does not ask for that body again until the daemon starts again.
The pulls of A also repair a revision that damage in the middle of its segment hit (see [Recovery](#recovery)).

### The index hash

The index hash is the SHA-256 of the newest revision of each entry, a `remove` too, in the order of the ids, each as `<id> <rev> <length>`, a newline and the body.
Two nodes with the same hash have the same bodies. The signatures are not in the hash, because a body can have more than one good signature.
`GET /pond/node` gives the hash and the number of listed entries.

### The rule of a merge

The rule of `docs/protocol.md` refuses a different body at the same `rev`. For a merge from a peer, that rule is not enough. Two phones can save two bodies with the same `rev` on two nodes, and then each node keeps its own body for all time.
Thus a merge takes the body that sorts later at the same `rev`. Each node makes the same choice, so the nodes converge. Reason: without the rule, the index hashes of the nodes never become the same.
A local save keeps the rule of `docs/protocol.md`. A local save at the same `rev` as the store gets `Conflict`.

### Requests between nodes

`POST /pond/sync` has the request body in FastCGI `STDIN`, and the base64 DER signature of the body in the `HTTP_SIGNATURE` parameter.
The first line of the body is the kind (`index` or `bodies`), and the second line is the name of the node that asks. The node that replies reads `nodes/<name>.pub`.

| Reply | When |
|---|---|
| 200 | The signature is good. |
| 400 | The kind is not `index` or `bodies`. |
| 403 | No good signature from the key of the node that the body names. |
| 405 | The method is not `POST`. |

A request has no time and no nonce. Reason: a pull only reads, and it gives only the newest bodies, which are public, and their signatures. Thus a replay of a request gives nothing that is secret, and the sync does not need the clocks of the nodes to agree.

### Logs of the sync

| Log line | Cause |
|---|---|
| `took <n> revisions from <peer>` | A pull merged `n` revisions. |
| `cannot reach <peer>` | A pull got no reply. The daemon logs it one time, when the peer goes down. |
| `reached <peer>` | A pull got a reply after `cannot reach`. |
| `refused <id> rev <n> from <peer>: ...` | See [A pull](#a-pull). |
| `cannot save a pulled body in the store` | The append failed. The next pull tries again. |

### The sync test

`server/sync_test.py` starts 3 daemons on this machine, `server`, `desktop` and `mac`, each with its own node key and store. A proxy in the test is on each link from one node to another, so the test can cut the links of a node while the node runs.
The test saves signed entries with pond_save in the `entries/` of each node, and keeps a model: the winner of each entry over all the saves that a node accepted.
A measure of convergence is the time until the 3 index hashes are the same and the nodes list the winner of the model for each entry.

```
server/build.sh && python3 server/sync_test.py [kills]   # 100 kills if not given
```

- **The first sync**: 20 saves on the server come to the other 2 nodes.
- **Requests**: a sync request with no signature, or with a phone signature, gets 403. A `GET` gets 405.
- **A bad phone signature**: the server has a key that the others do not have. The desktop and the Mac refuse the body of that key, and log it one time. A higher `rev` with a good signature then replaces it on all nodes.
- **Partitions**: the test cuts each node in turn. Both sides save new entries, and the same entry at the same `rev` with other bodies. While the cut stays, the hash of the cut node differs. After the heal, the nodes converge within 60 s.
- **Sleep**: the Mac process stops (SIGSTOP) for 15 s, and its peers wait for their replies. After it continues, the nodes converge.
- **Clock skew**: the server saves with file times a day ahead, and the desktop with file times a day behind. The higher `rev` wins on all nodes.
- **Kills**: SIGKILL of a random node, at a random time while the nodes save and pull, then a start. The nodes converge to the model, and no node lists a `rev` that goes back.
- **100 writers**: 100 writers at the same time on 3 devices. Each device saves to its own node, each writer with the `rev` after the one that it saw last, as the outbox does after a 409. The nodes converge to the model, and no node lists a `rev` that goes back.

### Measured results of the sync

All the tests of `server/sync_test.py` pass on the Mac (macOS, APFS), with 100 kills, on 2026-10-28. The other tests of `server/test.sh` and `store/test.sh` also pass there.
Linux and OpenBSD were not measured for the sync. The real nodes and WireGuard were not used, because the deploy needs the node keys of the captain.

| Measure | Result | Target |
|---|---|---|
| Convergence after the heal of a partition of the server, the desktop and the Mac | 2.0 s, 2.4 s and 2.4 s | 60 s |
| Convergence after the Mac sleeps for 15 s | 0.1 s | 60 s |
| Convergence after 100 kills with SIGKILL at a random time | 4.2 s: each saved winner on each node | 60 s |
| 100 writers on 3 devices, 293 saves | convergence in 4.1 s; 0 `rev` that goes back in 189 reads | no `rev` that goes back |
| The kills | 0 `rev` that goes back in 3,912 reads of the 3 nodes | no `rev` that goes back |
| A body with no good phone signature | refused by both peers, and logged one time | refused |

A pull each 5 s and a scan of `entries/` each second give the time of convergence. Most of a measure is the wait for the next pull.

## Install

The files are in `server/service/`. Each file has the paths of its system. Build on the node with `server/build.sh` first.

### OpenBSD (the server)

1. Install the programs and the rc.d script:
   ```
   install -m 755 server/pond_node server/pond_shadow /usr/local/bin/
   install -m 555 server/service/pond_node.rc /etc/rc.d/pond_node
   ```
2. Make the user and the store directory:
   ```
   useradd -L daemon -g =uid -s /sbin/nologin -d /var/empty _pondnode
   install -d -o _pondnode -m 700 /var/pond-node
   ```
3. Add the lines of `server/service/httpd.conf` to `/etc/httpd.conf`. They add a server on 127.0.0.1 port 8789 that sends the 4 paths to the daemon. The public server does not change in phase 2.
4. Check the configuration with `httpd -n`.
5. Start the daemon and load the new httpd configuration:
   ```
   rcctl enable pond_node
   rcctl start pond_node
   rcctl reload httpd
   ```
6. Add the cron line of the compare tool (see [The compare tool](#the-compare-tool)).
7. Read the log of the daemon in `/var/log/daemon`. The first line gives the number of entries in the store.

To add the WireGuard address, run `rcctl set pond_node flags` with the flags of the script and `--wireguard <address>`.

### Linux (the NixOS desktop)

1. Build with OpenSSL: `nix-shell -p openssl gcc --run server/build.sh`.
2. Install `server/pond_node` as `/usr/local/bin/pond_node`.
3. Install `server/service/pond-node.service` as `/etc/systemd/system/pond-node.service`.
4. Start the daemon: `systemctl daemon-reload && systemctl enable --now pond-node`.

On NixOS, `/etc` is read-only. Put the settings of the unit in `systemd.services.pond-node` of the system configuration, with the path of the program in the Nix store.

### macOS (the Mac)

1. Install the program and make the directories:
   ```
   mkdir -p ~/bin "$HOME/Library/Application Support/pond-node/pond/entries" "$HOME/Library/Application Support/pond-node/pond/keys"
   cp server/pond_node ~/bin/
   ```
2. Copy the page template to `~/Library/Application Support/pond-node/pond/template.html`.
3. Install the agent with the home directory in place of `HOME`:
   ```
   sed "s|HOME|$HOME|g" server/service/org.teoyujie.pond-node.plist > ~/Library/LaunchAgents/org.teoyujie.pond-node.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.teoyujie.pond-node.plist
   ```
4. Read the log in `~/Library/Logs/pond_node.log`.

Until phase 4, only the server gets entries from the phone. On the desktop and the Mac, `entries/` stays empty, and the store gets the entries through the sync.

### Sync between the nodes

Do these steps on each node after the install above. The node names are `server`, `desktop` and `mac`. `<pond>` is the `--pond` directory of the node.

1. A store from phase 2 has no signatures in its records, so its peers cannot check its bodies. Stop the daemon, delete `store.seg` in the store directory, and start the daemon. It imports the entry files again, with their signatures.
2. Make the node key on the node itself. The private key does not leave the node:
   ```
   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out node.pem
   openssl pkey -in node.pem -pubout -outform DER | openssl base64 -A > <name>.pub
   ```
   - OpenBSD: put `node.pem` in `/etc/pond-node/`, owner `_pondnode`, mode 400.
   - Linux: put it in `/etc/pond-node/`, owner root, mode 400. Add `LoadCredential=node-key:/etc/pond-node/node.pem` to the unit, and give `--node-key ${CREDENTIALS_DIRECTORY}/node-key`.
   - macOS: put it in `~/Library/Application Support/pond-node/`, mode 400.
3. Copy the 3 public files `<name>.pub` to `<pond>/nodes/` on each node.
4. Copy the phone keys of the server, `/var/www/pond/keys/*.pub`, to `<pond>/keys/` on the desktop and the Mac. A node refuses each body of a key that is not in its `keys/`.
5. Add the flags to the service file of the node: `--wireguard <its WireGuard address> --node <name> --node-key <file>`, and `--peer <WireGuard address>:8788` for each of the other 2 nodes.
6. Start the daemon again. The log has `took <n> revisions from <peer>` after the first pull, and `cannot reach <peer>` while a peer is down.
7. Check that the 3 nodes have the same index hash: `pond_shadow get fcgi 8788 /pond/node` on each node.

## Tests of the daemon

`server/test.sh` also tests the daemon. It starts `pond_node` on a test directory with port 0, and checks these points:

- The daemon serves the same bytes as pond_read, and imports each entry one time.
- An unknown path gets 404, and a `POST` gets 405.
- The daemon sends no reply to a request that is not FastCGI.
- 3 saves of one date, in the name order a, m and z, come in the order z, m and a, as from pond_read.
- An entry file with a signature of the wrong key is refused. The compare tool reports `only pond_read has forged rev 1`, and the daemon logs the refusal.
- After a `remove`, the compare tool reports no difference.
- 8 FastCGI clients get 400 good replies.
- After a SIGKILL and a start, the compare tool reports no difference, and the store does not get the same records again.
- Two entry files with the same time come in the order of pond_read.
- `--wireguard 0.0.0.0` stops the daemon with exit status 1.

`server/bench.sh` saves 1,000 signed entries with pond_save, runs the compare tool, then measures `/log/` from pond_read and from the daemon.

## Measured results of the daemon

The tests of `server/test.sh` pass on macOS, Linux (NixOS) and OpenBSD 8.0. The numbers are from 2026-10-28, on a log of 1,000 entries, for `GET /log/`.
The real server was not measured, because this task does not change the server. The OpenBSD VM has the same system and the same httpd and slowcgi setup.

`pond_shadow bench` sends the requests from 1 or 8 client threads, and gives the requests each second and the time of each request at the 50th and the 99th percentile.
"CGI" is one pond_read process for each request, as slowcgi runs it today. "Daemon" is pond_node.

**OpenBSD 8.0 VM** (2 CPUs, on the desktop), through httpd, as the public site will use it. CGI is httpd, slowcgi and pond_read. Daemon is httpd and pond_node over FastCGI. The daemon ran under rc.d as `_pondnode`, with `pledge` and `unveil`, and the compare tool reported no difference.

| Clients | CGI | Daemon | Daemon / CGI |
|---|---|---|---|
| 1 | 126 requests/s, p50 7.7 ms, p99 10.7 ms | 1,618 requests/s, p50 0.61 ms, p99 0.71 ms | 12.8 |
| 8 | 176 requests/s, p50 40.2 ms, p99 103.5 ms | 1,843 requests/s, p50 4.3 ms, p99 5.9 ms | 10.5 |

**Mac** (`server/bench.sh`, with no httpd). The bench tool connects to the daemon directly over FastCGI, and runs pond_read itself for CGI.

| Clients | CGI | Daemon, FastCGI | Daemon / CGI |
|---|---|---|---|
| 1 | 13 requests/s, p99 204.8 ms | 733 requests/s, p99 5.2 ms | 56 |
| 8 | 43 requests/s, p99 611.9 ms | 2,524 requests/s, p99 11.5 ms | 59 |

**Linux** (the NixOS desktop, 16 CPU threads, `server/bench.sh`, with no httpd):

| Clients | CGI | Daemon, FastCGI | Daemon / CGI |
|---|---|---|---|
| 1 | 105 requests/s, p99 10.2 ms | 3,033 requests/s, p99 0.44 ms | 29 |
| 8 | 879 requests/s, p99 11.9 ms | 22,415 requests/s, p99 0.49 ms | 25 |

The targets are a p99 of `/log/` under 50 ms, and 10 times the throughput of CGI. The daemon meets both targets on each system.
In the VM, the 2 CPUs run httpd, the bench tool and the daemon at the same time. Thus with 8 clients, the CPUs limit the daemon, and the ratio is lowest there.
On the Mac, each new TCP connection on 127.0.0.1 costs about 1 ms, also with a Python server. Thus the cause is the Mac, not the daemon.
A CGI process on the Mac costs much more than on OpenBSD, so the Mac ratio is high. The VM ratio through httpd is the best estimate for the server.

A first bench in the VM stopped for 20 minutes: some client threads slept in `connect` after the connection was made. The bench tool now uses a `connect` that does not block, with a `poll` of 100 ms at a time and a limit of 5 s.
