// The Pond store: the storage engine for the entries of the log. One
// append-only segment file holds each accepted revision of each entry as a
// record with a checksum. An index in memory finds the newest revision of an
// entry by its id, and lists the entries newest first by date, or with one
// tag. Each body stays byte for byte the signed request body.
// docs/store.md is the design; docs/protocol.md has the rules it keeps.
//
// The state is in globals, so a program (or a thread, which gets its own
// copy of the globals) has one store open at a time. Many processes and
// threads can have the same store open: a write holds an flock on
// store.lock, and reads the records of the others first.

import std;
import os;
import json;
import dictionary;

namespace store;

// store_io.h: the file calls that os has no form of.
extern "store_open" fn open_file(path: const u8[:], write: bool) -> i32;
extern "store_create" fn create_file(path: const u8[:]) -> i32;
extern "store_close" fn close_file(fd: i32);
extern "store_lock" fn lock_file(fd: i32) -> bool;
extern "store_unlock" fn unlock_file(fd: i32);
extern "store_size" fn file_size(fd: i32) -> i64;
extern "store_inode" fn file_inode(fd: i32) -> i64;
extern "store_path_inode" fn path_inode(path: const u8[:]) -> i64;
extern "store_read" fn read_at(fd: i32, at: i64, n: i64, out: u8[>..]&) -> bool;
extern "store_write" fn write_end(fd: i32, data: const u8[:]) -> bool;
extern "store_sync" fn sync_file(fd: i32) -> bool;
extern "store_truncate" fn truncate_file(fd: i32, size: i64) -> bool;
extern "store_sync_dir" fn sync_dir(path: const u8[:]) -> bool;

// A record: the magic, the body length (u32, little-endian), the CRC-32C of
// the length and the body (u32, little-endian), then the body. 0xFF is in
// no UTF-8 text, so the magic is not in a JSON body.
let MAGIC: u8[4] = [255, 80, 78, 68];
let HEADER = 12;
let MAX_BODY = 8192;

// The index item of one entry: its newest revision.
struct Entry {
    id: u8[..64],
    rev: i64,
    at: i64,            // the start of the body, in the segment
    size: i64,          // the body length
    seq: i64,           // the number of the record in the segment: the order of the changes
    removed: bool,      // the newest revision is a remove
    date_at: i64,       // the date and the tag, in strs, with JSON escapes decoded
    date_len: i64,
    tag_at: i64,
    tag_len: i64,
}

// Bytes that are not a whole record with a good checksum: in the middle of
// the segment, with a good record after them, or at the end, where they have
// the magic, a length and all of the bytes of a record.
struct Damage { at: i64, size: i64 }

enum Status { Created, Same, Conflict, Invalid, Failed }

var seg_path: u8[..1024];
var lock_path: u8[..1024];
var dir_path: u8[..1024];
var writer = false;
var seg_fd: i32 = -1;
var lock_fd: i32 = -1;
var seg_inode: i64 = -1;
var records = 0;            // the whole records in data
var torn = 0;               // bytes at the end of the file that are not a whole record
var data: u8[>..];          // the segment, up to the end of its last whole record
var strs: u8[>..];
var entries: Entry[>..];
var by_id = dictionary<u8[..64], i64> {};
var order: i64[>..];        // the listed entries, newest first, when sorted is true
var by_tag: i64[>..];       // the listed entries with a tag, by the tag, then newest first
var sorted = false;
var damage: Damage[>..];

fn crc_table() -> u32[256] {
    var t: u32[256] = [0; 256];
    for i in 256 {
        var c = i as! u32;
        for k in 8 { c = if (c & 1) != 0 { (c >> 1) ^ 0x82F63B78 } else { c >> 1 }; }
        t[i] = c;
    }
    return t;
}

let CRC = crc_table();

// CRC-32C (Castagnoli): its polynomial finds more of the errors of short
// records than the CRC-32 of zip.
fn crc32c(c0: u32, s: u8[:]) -> u32 {
    var c = c0;
    for b in s { c = CRC[(c ^ b) & 0xFF] ^ (c >> 8); }
    return c;
}

fn checksum(len_bytes: u8[:], body: u8[:]) -> u32 {
    return crc32c(crc32c(0xFFFFFFFF, len_bytes), body) ^ 0xFFFFFFFF;
}

fn put_u32(out: u8[>..]&, v: u32) {
    for k in 4 { out.push(((v >> (8 * k) as! u32) & 0xFF) as! u8); }
}

fn get_u32(s: u8[:], at: i64) -> u32 {
    var v: u32 = 0;
    for k in 4 { v |= (s[at + k] as u32) << (8 * k) as! u32; }
    return v;
}

// An id is also a name in the index and in a file, so it has only these
// characters (docs/protocol.md).
fn is_name(s: u8[:]) -> bool {
    guard s.len >= 1 && s.len <= 64 else { return false; }
    return all(s) { (it >= 'a' && it <= 'z') || (it >= 'A' && it <= 'Z') || (it >= '0' && it <= '9') || it == '-' };
}

// What the index takes from a body. The date and the tag go on the end of
// out; Meta has their lengths.
struct Meta { id: u8[..64], rev: i64, removed: bool, date_len: i64, tag_len: i64 }

// A body is a put of an id with a rev and an entry with a date, or a remove.
// The tag of an entry is its interest. The save service checks the rest of
// the request before it comes here.
fn meta(body: u8[:], out: u8[>..]&) -> Meta, bool {
    var m = Meta { .. };
    guard body.len >= 1 && body.len <= MAX_BODY else { return m, false; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(body, doc, decoded);
    guard root else { return m, false; }
    let op, op_ok = json::as_string(json::member(root, "op"));
    let id, id_ok = json::as_string(json::member(root, "id"));
    let rev, rev_ok = json::as_i64(json::member(root, "rev"));
    let entry = json::member(root, "entry");
    guard id_ok && is_name(id) && rev_ok && rev >= 1 else { return m, false; }
    m.id.append(id);
    m.rev = rev;
    if op_ok && op == "remove" && !entry {
        m.removed = true;
        return m, true;
    }
    let date, date_ok = json::as_string(json::member(entry, "date"));
    guard op_ok && op == "put" && date_ok else { return m, false; }
    let tag, tag_ok = json::as_string(json::member(entry, "interest"));
    out.append(date);
    m.date_len = date.len;
    if tag_ok {
        out.append(tag);
        m.tag_len = tag.len;
    }
    return m, true;
}

// The size of the record at offset at of data, if it has the magic, a length
// of 1 to MAX_BODY and all of its bytes, or 0. The checksum can be bad.
fn whole_at(at: i64) -> i64 {
    guard at >= 0 && at + HEADER <= data.len else { return 0; }
    guard data[at..at + 4] == MAGIC[..] else { return 0; }
    let n = get_u32(data, at + 4) as i64;
    guard n >= 1 && n <= MAX_BODY && at + HEADER + n <= data.len else { return 0; }
    return HEADER + n;
}

// The size of the whole record with a good checksum at offset at of data,
// or 0.
fn record_at(at: i64) -> i64 {
    let n = whole_at(at);
    guard n > 0 && get_u32(data, at + 8) == checksum(data[at + 4..at + 8], data[at + HEADER..at + n]) else { return 0; }
    return n;
}

// F(at, size, good) for each whole record in data from offset from, and for
// each range of damage (good false) that has a whole record after it. The
// result is the end of the last whole record.
fn walk<F>(from: i64) -> i64 {
    var at = from;
    var end = from;
    while at < data.len {
        let n = record_at(at);
        if n > 0 {
            F(at, n, true);
            at += n;
            end = at;
            continue;
        }
        var next = at + 1;
        var found = false;
        while next < data.len {
            let k = find(data[next..], MAGIC[..]);
            guard k >= 0 else { break; }
            next += k;
            if record_at(next) > 0 { found = true; break; }
            next += 1;
        }
        guard found else { break; }
        F(at, next - at, false);
        at = next;
    }
    return end;
}

// Puts the record at offset at in the index. A rev that is not higher than
// the index has is an old revision, and changes nothing.
fn index(at: i64, n: i64) {
    let body = data[at + HEADER..at + n];
    let start = strs.len;
    let m, ok = meta(body, strs);
    guard ok else {
        strs.resize(start);
        damage.push(Damage { at: at, size: n });
        return;
    }
    let seq = records;
    records++;
    let have = ::get(by_id, m.id);
    if have {
        let e .= entries[have];
        guard m.rev > e.rev else { strs.resize(start); return; }
        e.rev = m.rev;
        e.at = at + HEADER;
        e.size = n - HEADER;
        e.seq = seq;
        e.removed = m.removed;
        e.date_at = start;
        e.date_len = m.date_len;
        e.tag_at = start + m.date_len;
        e.tag_len = m.tag_len;
    } else {
        by_id.insert(m.id, entries.len);
        entries.push(Entry {
            id: m.id, rev: m.rev, at: at + HEADER, size: n - HEADER, seq: seq, removed: m.removed,
            date_at: start, date_len: m.date_len, tag_at: start + m.date_len, tag_len: m.tag_len,
        });
    }
    sorted = false;
}

// Reads the records that the file has past data, and indexes them. In a
// writer, which holds the lock, a torn record at the end is cut off the file.
// A whole record with a bad checksum at the end is damage: no write cuts it.
fn catch_up() -> bool {
    // A compaction by another process put a new segment at the path, or the
    // file got shorter, which no write of the store does: read it again.
    if seg_fd >= 0 && (path_inode(seg_path) != seg_inode || file_size(seg_fd) < data.len) { reset(); }
    if seg_fd < 0 {
        seg_fd = open_file(seg_path, writer);
        guard seg_fd >= 0 else { return !writer; }
        seg_inode = file_inode(seg_fd);
    }
    // The damage at the end from the last read: this read finds it again.
    if damage.len > 0 && last(damage).at == data.len { damage.pop(); }
    let size = file_size(seg_fd);
    guard size >= data.len else { return false; }
    let start = data.len;
    guard read_at(seg_fd, start, size - start, data) else { data.resize(start); return false; }
    let end = walk(start) { at, n, good =>
        if good { index(at, n); } else { damage.push(Damage { at: at, size: n }); }
    };
    let damaged_end = whole_at(end) > 0;
    if damaged_end { damage.push(Damage { at: end, size: size - end }); }
    data.resize(end);
    torn = size - end;
    if writer && torn > 0 && !damaged_end {
        guard truncate_file(seg_fd, end) else { return false; }
        torn = 0;
    }
    return true;
}

// Forgets the segment, so that the next catch_up reads it from the start.
fn reset() {
    close_file(seg_fd);
    seg_fd = -1;
    seg_inode = -1;
    records = 0;
    torn = 0;
    data.clear();
    strs.clear();
    entries.clear();
    by_id.clear();
    order.clear();
    by_tag.clear();
    sorted = false;
    damage.clear();
}

fn set_path(out: u8[..1024]&, dir: u8[:], name: u8[:]) -> bool {
    out.clear();
    guard dir.len + 1 + name.len <= 1023 else { return false; }
    out.append(dir);
    out.push('/');
    out.append(name);
    return true;
}

// Opens the store in the directory dir: store.seg and store.lock. A writer
// makes the files if they are not there, and recovers after a crash in the
// middle of a write: it cuts a torn record off the end of the segment, but
// not a whole record with a bad checksum. A
// reader (write false) changes no file, and does not see a torn record.
fn open(dir: u8[:], write: bool) -> bool {
    close();
    guard set_path(seg_path, dir, "store.seg") && set_path(lock_path, dir, "store.lock") else { return false; }
    dir_path.clear();
    dir_path.append(dir);
    writer = write;
    if writer {
        lock_fd = open_file(lock_path, true);
        guard lock_fd >= 0 && lock_file(lock_fd) else { close(); return false; }
        let ok = catch_up() && sync_dir(dir_path);
        unlock_file(lock_fd);
        if !ok { close(); }
        return ok;
    }
    return catch_up();
}

fn close() {
    reset();
    close_file(lock_fd);
    lock_fd = -1;
}

// Reads the changes that other processes and threads made since the last
// call. A long-running reader calls it before it serves.
fn refresh() -> bool {
    guard !writer || lock_file(lock_fd) else { return false; }
    let ok = catch_up();
    if writer { unlock_file(lock_fd); }
    return ok;
}

fn status_text(s: Status) -> const u8[:] {
    match s {
        Created => "created",
        Same => "same",
        Conflict => "conflict",
        Invalid => "invalid",
        Failed => "failed",
    }
}

// Saves body, the exact bytes of a signed request, as the newest revision of
// its entry, with the rule of docs/protocol.md: the higher rev wins; the same
// body again is a retry and changes nothing; any other body with a rev that
// is not higher is refused. The second result is the rev that the store had
// for the id, or 0. Created comes back only after the record is on the disk.
// A store with damage at the end refuses all appends with Failed.
fn append(body: u8[:]) -> Status, i64 {
    guard writer else { return Status.Failed, 0; }
    var scratch: u8[>..] = [];
    let m, ok = meta(body, scratch);
    guard ok else { return Status.Invalid, 0; }
    // The lock makes the rev check and the write one step for all the
    // processes and threads that have the store open.
    // A copy, as the caller's bytes can be in data, which catch_up can cut.
    var own: u8[>..] = [];
    own.append(body);
    guard lock_file(lock_fd) else { return Status.Failed, 0; }
    let status, rev = locked_append(own, m.id, m.rev);
    unlock_file(lock_fd);
    return status, rev;
}

fn locked_append(body: u8[:], id: u8[..64], rev: i64) -> Status, i64 {
    guard catch_up() && torn == 0 else { return Status.Failed, 0; }
    let have = ::get(by_id, id);
    var old_rev = 0;
    if have {
        let e = entries[have];
        old_rev = e.rev;
        if data[e.at..e.at + e.size] == body { return Status.Same, old_rev; }
        guard rev > old_rev else { return Status.Conflict, old_rev; }
    }
    var rec: u8[>..] = [];
    rec.append(MAGIC[..]);
    put_u32(rec, body.len as! u32);
    put_u32(rec, checksum(rec[4..8], body));
    rec.append(body);
    let at = data.len;
    guard write_end(seg_fd, rec) && sync_file(seg_fd) else {
        // A short write leaves a torn record; the next write cuts it off.
        truncate_file(seg_fd, at);
        return Status.Failed, old_rev;
    }
    data.append(rec);
    index(at, rec.len);
    return Status.Created, old_rev;
}

// The newest revision of the entry id, a put or a remove, or null.
fn get(id: u8[:]) -> Entry? {
    guard is_name(id) else { return null; }
    var key: u8[..64] = [];
    key.append(id);
    let have = ::get(by_id, key);
    guard have else { return null; }
    return entries[have];
}

fn body(e: Entry&) -> const u8[:] { data[e.at..e.at + e.size] }
fn date(e: Entry&) -> const u8[:] { strs[e.date_at..e.date_at + e.date_len] }
fn tag(e: Entry&) -> const u8[:] { strs[e.tag_at..e.tag_at + e.tag_len] }

// Entry a is listed before entry b: the later date, then on the same date
// the later change.
fn newer(a: i64, b: i64) -> bool {
    let d = compare(date(entries[a]), date(entries[b]));
    return d > 0 || (d == 0 && entries[a].seq > entries[b].seq);
}

// Sorts the date list and the tag list again after a change.
fn sort_lists() {
    guard !sorted else { return; }
    order.clear();
    by_tag.clear();
    for e, i in entries {
        guard !e.removed else { continue; }
        order.push(i);
        if e.tag_len > 0 { by_tag.push(i); }
    }
    sort(order) { a, b => newer(a, b) };
    sort(by_tag) { a, b =>
        let d = compare(tag(entries[a]), tag(entries[b]));
        d < 0 || (d == 0 && newer(a, b))
    };
    sorted = true;
}

// The entries that are not removed, newest first. Each item is a place in
// entries.
fn newest_first() -> const i64[:] {
    sort_lists();
    return order;
}

// The listed entries with the tag t, newest first. An empty tag is no tag.
fn with_tag(t: u8[:]) -> const i64[:] {
    sort_lists();
    let from = lower_bound(by_tag) { compare(tag(entries[it]), t) < 0 };
    let to = lower_bound(by_tag) { compare(tag(entries[it]), t) <= 0 };
    return by_tag[from..to];
}

fn entry(i: i64) -> Entry& { entries[i] }

// F(body) for each whole record in the segment, in the order of the
// changes: old revisions too.
fn each_record<F>() {
    walk(0) { at, n, good => if good { F(data[at + HEADER..at + n]); } };
}

// Writes the newest revision of each entry to a new segment, which takes
// the place of the old one in one rename. A crash at any point leaves the
// old segment or the new one, and each has all the newest revisions. A
// store with damage is not compacted: the damage can be the newest
// revision of an entry, and the old bytes can still help to repair it.
fn compact() -> bool {
    guard writer && lock_file(lock_fd) else { return false; }
    let ok = locked_compact();
    unlock_file(lock_fd);
    return ok;
}

fn locked_compact() -> bool {
    guard catch_up() && damage.len == 0 else { return false; }
    var keep: i64[>..] = [];
    for e, i in entries { keep.push(i); }
    sort(keep) { a, b => entries[a].seq < entries[b].seq };
    var next: u8[>..] = [];
    for i in keep {
        let e = entries[i];
        next.append(data[e.at - HEADER..e.at + e.size]);
    }
    var new_path: u8[..1024] = [];
    guard set_path(new_path, dir_path, "store.seg.new") else { return false; }
    let fd = create_file(new_path);
    guard fd >= 0 else { return false; }
    let written = write_end(fd, next) && sync_file(fd);
    close_file(fd);
    guard written && rename_file(new_path, seg_path) && sync_dir(dir_path) else { return false; }
    reset();
    return catch_up();
}

fn record_count() -> i64 { records }
fn entry_count() -> i64 { entries.len }
fn torn_bytes() -> i64 { torn }
fn damage_list() -> const Damage[:] { damage }
fn segment_size() -> i64 { data.len }
