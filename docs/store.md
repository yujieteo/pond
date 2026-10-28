# Pond: the store

The store is the storage engine for the entries of the log. It replaces one file for each entry with one append-only segment file.
`store/store.goose` is the engine, and `store/store_io.h` has the few file calls that Goose does not have.
This is phase 1 of 5: one node, with no daemon, no network and no sync. pond_save and pond_read do not use the store yet.

The store keeps the rules of `docs/protocol.md`:

- The higher `rev` wins. The same body again changes nothing. Any other body with a `rev` that is not higher is refused, and the reply names the saved `rev`.
- A `remove` is the newest revision of its entry. Thus a replay of an older `put` cannot bring the entry back.
- Each stored body is byte for byte the signed request body. The store does not change or encode it again. Reason: the signature is over the exact bytes, so a peer can check it again in phase 3.
- A write holds an exclusive lock from the `rev` check to the end of the write. Reason: two writes at the same time must not let a lower `rev` replace a higher `rev`.

## The API

| Call | What it does |
|---|---|
| `store::open(dir, write)` | Opens `dir/store.seg`. A writer makes the files if they are not there, and recovers after a crash (see [Recovery](#recovery)). A reader changes no file. |
| `store::append(body)` | Saves a body with the rule above. The result is `Created`, `Same`, `Conflict` (with the saved `rev`), `Invalid` or `Failed`. `Created` comes back only after the record is on the disk. |
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

The segment is a sequence of records. Each record is a header of 12 bytes, then the body:

| Bytes | Field |
|---|---|
| 0 to 3 | The magic `FF 50 4E 44` (`0xFF` and `PND`). |
| 4 to 7 | The length of the body, u32, little-endian: 1 to 8192. |
| 8 to 11 | The checksum: CRC-32C of bytes 4 to 7 and of the body, u32, little-endian. |
| 12 to the end | The body: the exact bytes of the signed request. |

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

`open` and `refresh` read the segment from the end of the last good record. A record is good if it has the magic, a length of 1 to 8192, all of its bytes, and a good checksum.

| What the store finds | What it does |
|---|---|
| A good record. | It adds the record to the index. |
| Bytes that are not a good record, and no good record after them, with no magic, a length that is not 1 to 8192, or fewer bytes than their length: a torn record from a crash in the middle of a write, or zeros from the file system. | A reader does not serve the bytes, and does not change the file. A writer, which holds the lock, cuts the bytes off the file before it appends. |
| Bytes that are not a good record, and no good record after them, with the magic, a length of 1 to 8192 and all of the bytes: damage in the last record. | The store does not serve the bytes, and adds them to the damage list. No write cuts the damage, each `append` gives `Failed`, and `compact` refuses to run. |
| Bytes that are not a good record, and a good record after them: damage in the middle. | The store does not serve the bytes, and adds them to the damage list. It reads the records after them as usual. No write cuts the damage, and `compact` refuses to run. |

A write gives the bytes of a record in sequence, so a crash in the middle of a write leaves fewer bytes than the length. Thus a record with all of its bytes and a bad checksum is damage to an acknowledged record, not a torn write.
A change in the magic of the last record makes it look like a torn record. A change in its length to a value that is not 1 to 8192, or past the end of the file, does the same. The writer cuts it.
The writer refuses to append after damage at the end. Reason: an append after it hides the damaged record from the operator, and the bytes of the damage stay for a repair.

A reader that reads while a writer writes can see a part of a record at the end. That part is a torn record to the reader, so the reader does not serve it. It reads the whole record at its next `refresh`.

Damage loses the record that it hits on this node. The store does not serve a changed body, and it serves all the other records.
If the lost record was the newest revision of its entry, `get` gives the revision before it until a repair.
In phase 3, a node pulls the revisions that it does not have from its peers, and that sync repairs the entry. Until then, the damage list tells the operator.
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
