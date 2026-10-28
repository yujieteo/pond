// The tests of the store that run in one process: the rules of
// docs/protocol.md, the index, torn and corrupt segments, compaction, and
// writer and reader threads at the same time. test.sh runs it with a new
// empty directory, and runs the crash tests, which need processes.

import std;
import os;
import dictionary;
import store;

var fails = 0;
var work: u8[..1024];

fn expect(name: u8[:], ok: bool) {
    if ok { print("pass: ", name); } else { print("FAIL: ", name); fails++; }
}

fn put(id: u8[:], rev: i64, date: u8[:], title: u8[:]) -> u8[>..] {
    return str("{\"entry\":{\"date\":\"", date, "\",\"title\":\"", title, "\"},\"id\":\"", id,
               "\",\"key\":\"phone\",\"op\":\"put\",\"rev\":", rev, ",\"v\":1}");
}

fn tagged(id: u8[:], rev: i64, date: u8[:], tag: u8[:]) -> u8[>..] {
    return str("{\"entry\":{\"date\":\"", date, "\",\"interest\":\"", tag, "\",\"title\":\"a paper\"},\"id\":\"", id,
               "\",\"key\":\"phone\",\"op\":\"put\",\"rev\":", rev, ",\"v\":1}");
}

fn remove(id: u8[:], rev: i64) -> u8[>..] {
    return str("{\"id\":\"", id, "\",\"key\":\"phone\",\"op\":\"remove\",\"rev\":", rev, ",\"v\":1}");
}

// A new empty store directory under the work directory.
fn fresh(name: u8[:]) -> u8[>..] {
    let dir = str(work, "/", name);
    guard make_dir(dir) else { abort(str("cannot make ", dir)); }
    return dir;
}

fn is(s: store::Status, want: store::Status) -> bool {
    return store::status_text(s) == store::status_text(want);
}

fn body_of(id: u8[:]) -> const u8[:] {
    let e = store::get(id);
    guard e else { return ""; }
    return store::body(e);
}

fn sig_of(id: u8[:]) -> const u8[:] {
    let e = store::get(id);
    guard e else { return ""; }
    return store::signature(e);
}

fn listed_ids(out: u8[>..]&, items: const i64[:]) {
    for i, k in items {
        if k > 0 { out.push(' '); }
        out.append(store::entry(i).id);
    }
}

let BAD = [
    "", "not json", "{\"id\":\"e2\",\"op\":\"put\",\"rev\":1}",
    "{\"entry\":{\"title\":\"no date\"},\"id\":\"e2\",\"op\":\"put\",\"rev\":1}",
    "{\"entry\":{\"date\":\"2026-10-28\"},\"id\":\"../e2\",\"op\":\"put\",\"rev\":1}",
    "{\"entry\":{\"date\":\"2026-10-28\"},\"id\":\"e2\",\"op\":\"put\",\"rev\":0}",
    "{\"entry\":{\"date\":\"2026-10-28\"},\"id\":\"e2\",\"op\":\"remove\",\"rev\":1}",
    "{\"entry\":{\"date\":\"2026-10-28\"},\"id\":\"e2\",\"op\":\"move\",\"rev\":1}",
];

fn test_rules() {
    let dir = fresh("rules");
    expect("a writer opens a new store", store::open(dir, true));
    let p1 = put("e1", 1, "2026-10-28", "1987 - IEEE Standard on Piezoelectricity");
    var s, rev = store::append(p1);
    expect("a new entry is created", is(s, store::Status.Created) && rev == 0);
    expect("get gives the exact body", body_of("e1") == p1);
    s, rev = store::append(p1);
    expect("the same body again changes nothing", is(s, store::Status.Same) && rev == 1);
    s, rev = store::append(put("e1", 1, "2026-10-28", "other"));
    expect("a different body at the same rev is refused, with the saved rev", is(s, store::Status.Conflict) && rev == 1);
    let p2 = put("e1", 2, "2026-10-28", "with a link");
    s, rev = store::append(p2);
    expect("a higher rev replaces the entry", is(s, store::Status.Created) && rev == 1 && body_of("e1") == p2);
    s, rev = store::append(p1);
    expect("a replay of the old rev is refused", is(s, store::Status.Conflict) && rev == 2 && body_of("e1") == p2);
    let r3 = remove("e1", 3);
    s, rev = store::append(r3);
    expect("a remove at a higher rev is saved", is(s, store::Status.Created) && body_of("e1") == r3);
    s, rev = store::append(p2);
    expect("after a remove, a replay of a put is refused", is(s, store::Status.Conflict) && rev == 3);
    expect("a removed entry is not listed", store::newest_first().len == 0);
    for k in BAD.len {
        let st, r = store::append(BAD[k]);
        expect(str("a body that is not a put or a remove is refused: ", BAD[k]), is(st, store::Status.Invalid));
    }
    var big: u8[>..] = [];
    big.append(put("e2", 1, "2026-10-28", ""));
    while big.len <= 8192 { big.insert_at(30, 'x'); }
    let sb, rb = store::append(big);
    expect("a body over 8192 bytes is refused", is(sb, store::Status.Invalid));
    expect("a refused body is not saved", store::record_count() == 3 && store::entry_count() == 1);

    // The index: newest first by the date, then by the change; and by tag.
    store::append(put("old", 1, "2026-10-27", "old"));
    store::append(put("morning", 1, "2026-10-28", "morning"));
    store::append(tagged("paper", 1, "2026-10-28", "biology"));
    store::append(put("evening", 1, "2026-10-28", "evening"));
    store::append(tagged("other", 1, "2026-10-26", "math"));
    store::append(tagged("esc", 1, "2026-10-25", "bio\\u006cogy"));
    var ids: u8[>..] = [];
    listed_ids(ids, store::newest_first());
    expect("newest first: the later date, then the later change", ids == "evening paper morning old other esc");
    ids.clear();
    listed_ids(ids, store::with_tag("biology"));
    expect("by tag, newest first, with JSON escapes decoded", ids == "paper esc");
    store::append(tagged("paper", 2, "2026-10-28", "math"));
    store::append(remove("other", 2));
    ids.clear();
    listed_ids(ids, store::with_tag("biology"));
    expect("a new tag takes an entry off its old tag", ids == "esc");
    ids.clear();
    listed_ids(ids, store::with_tag("math"));
    expect("a new tag puts an entry under it, and a removed entry is under no tag", ids == "paper");
    ids.clear();
    store::append(put("morning", 2, "2026-10-28", "morning, changed"));
    listed_ids(ids, store::newest_first());
    expect("a change moves an entry up on its date", ids == "morning paper evening old esc");
    expect("an entry with no tag is not under a tag", store::with_tag("").len == 0);
    let keep = copy(ids);

    expect("a reader opens the same store", store::open(dir, false));
    ids.clear();
    listed_ids(ids, store::newest_first());
    expect("the reader has the same index", ids == keep && body_of("e1") == r3);
    let s3, r3b = store::append(put("new", 1, "2026-10-28", "x"));
    expect("a reader cannot append", is(s3, store::Status.Failed));
    store::close();
}

// Body k of a test segment.
fn sample_body(k: i64) -> u8[>..] {
    return put(str("e", k % 7), k / 7 + 1, str("2026-10-", 10 + k % 20), str("entry ", k));
}

// A test segment of n bodies, and the end of each record in the file.
fn sample(dir: u8[:], n: i64, ends: i64[>..]&) {
    guard store::open(dir, true) else { abort("cannot open"); }
    for k in n {
        store::append(sample_body(k));
        ends.push(store::segment_size());
    }
    store::close();
}

// The store holds exactly the first n bodies of the sample, in order.
fn holds(n: i64) -> bool {
    var k = 0;
    var ok = true;
    store::each_record() { body =>
        if k >= n || body != sample_body(k) { ok = false; }
        k++;
    };
    return ok && k == n;
}

// The number k of a body of the sample, or -1 if it is no body of it.
fn sample_number(body: u8[:]) -> i64 {
    let at = find(body, "\"title\":\"entry ");
    guard at >= 0 else { return -1; }
    let rest = body[at + 15..];
    let k, ok = parse_int(rest[..find(rest, "\"")]);
    guard ok && body == sample_body(k) else { return -1; }
    return k;
}

fn test_torn() {
    let dir = fresh("torn");
    var ends: i64[>..] = [];
    sample(dir, 12, ends);
    var whole: u8[>..] = [];
    let seg = str(dir, "/store.seg");
    guard read_file(seg, whole) else { abort("cannot read the segment"); }
    // A cut at each byte: what a crash leaves after a part of the last write.
    var bad_reads = 0;
    var bad_writes = 0;
    for cut in whole.len + 1 {
        var n = 0;
        while n < ends.len && ends[n] <= cut { n++; }
        let end = if n == 0 { 0 } else { ends[n - 1] };
        write_file(seg, whole[..cut]);
        if !store::open(dir, false) || !holds(n) || store::torn_bytes() != cut - end { bad_reads++; }
        if !store::open(dir, true) || !holds(n) || store::torn_bytes() != 0 { bad_writes++; }
        var after: u8[>..] = [];
        read_file(seg, after);
        if after.len != end { bad_writes++; }
        let s, r = store::append(sample_body(n));
        if n < ends.len && !is(s, store::Status.Created) { bad_writes++; }
    }
    expect(str("a reader serves only the whole records, after a cut at each of ", whole.len + 1, " bytes"), bad_reads == 0);
    expect("a writer cuts the torn record off, and appends after it", bad_writes == 0);

    // Zeros, as a file system can leave after a crash, and random bytes.
    var r = rng { 7 };
    for tail in 3 {
        var t = copy(whole);
        for k in 1 + r.rand_int(9000) { t.push(if tail == 0 { 0 } else { r.rand_u64() as! u8 }); }
        if tail == 2 { t.append(store::MAGIC[..]); }
        write_file(seg, t);
        let opened = store::open(dir, false);
        expect(str("a tail of junk is not served (", tail, ")"), opened && holds(ends.len) && store::torn_bytes() == t.len - whole.len);
    }
    store::close();
}

fn test_corrupt() {
    let dir = fresh("corrupt");
    var ends: i64[>..] = [];
    sample(dir, 40, ends);
    var whole: u8[>..] = [];
    let seg = str(dir, "/store.seg");
    guard read_file(seg, whole) else { abort("cannot read the segment"); }
    let last_start = ends[ends.len - 2];
    var r = rng { 11 };
    var bad = 0;
    let trials = 2000;
    for trial in trials {
        var t = copy(whole);
        // One byte changed, or a run of bytes, in a record before the last.
        let at = r.rand_int(last_start);
        let run = min(if trial % 2 == 0 { 1 } else { 1 + r.rand_int(64) }, last_start - at);
        for k in run { t[at + k] ^= (1 + r.rand_int(255)) as! u8; }
        write_file(seg, t);
        var hit = 0;
        for k in ends.len {
            let start = if k == 0 { 0 } else { ends[k - 1] };
            if at < ends[k] && at + run > start { hit++; }
        }
        guard store::open(dir, true) else { bad++; continue; }
        var served = 0;
        var changed = false;
        store::each_record() { body =>
            served++;
            if sample_number(body) < 0 { changed = true; }
        };
        if changed || served != ends.len - hit || store::damage_list().len == 0 {
            if bad == 0 { print("note: first bad trial ", trial, ": at ", at, " run ", run, " hit ", hit, " served ", served, " changed ", changed, " damage ", store::damage_list().len); }
            bad++;
        }
        // The damage stays in the file for a repair: no write cuts it.
        var after: u8[>..] = [];
        read_file(seg, after);
        if after != t { bad++; }
        if store::compact() { bad++; }
    }
    expect(str("damage in the middle, ", trials, " times: only the hit records are lost, none is changed, the damage is reported"), bad == 0);

    // A change in the last record, which has all of its bytes, is damage too.
    var t = copy(whole);
    t[whole.len - 5] ^= 1;
    write_file(seg, t);
    let opened = store::open(dir, true) && holds(ends.len - 1);
    let damage = store::damage_list();
    let reported = damage.len == 1 && damage[0].at == last_start && damage[0].size == whole.len - last_start;
    let s, rev = store::append(sample_body(ends.len));
    var after: u8[>..] = [];
    read_file(seg, after);
    expect("damage in the last record is reported, not cut, and the writer refuses to append",
           opened && reported && is(s, store::Status.Failed) && after == t && !store::compact());
    expect("a refresh reports the damage at the end once", store::refresh() && store::damage_list().len == 1);

    // Zeros in place of the last record, as a power loss can leave: no magic,
    // so a torn record.
    t = copy(whole);
    for k in whole.len - last_start { t[last_start + k] = 0; }
    write_file(seg, t);
    let zero_opened = store::open(dir, true) && holds(ends.len - 1) && store::damage_list().len == 0;
    after.clear();
    read_file(seg, after);
    let s2, rev2 = store::append(sample_body(ends.len - 1));
    expect("zeros in place of the last record are cut off like a torn record, and the writer appends",
           zero_opened && after == whole[..last_start] && is(s2, store::Status.Created) && holds(ends.len));
    store::close();
}

fn test_compact() {
    let dir = fresh("compact");
    var ends: i64[>..] = [];
    sample(dir, 200, ends);
    guard store::open(dir, true) else { abort("cannot open"); }
    store::append(remove("e3", 100));
    var before: u8[>..] = [];
    listed_ids(before, store::newest_first());
    let size_before = store::segment_size();
    expect("a reader opens before the compaction", store::open(dir, false));
    var reader_before: u8[>..] = [];
    listed_ids(reader_before, store::newest_first());
    expect("a writer opens again", store::open(dir, true));
    expect("compact succeeds", store::compact());
    expect("compact keeps one record for each entry", store::record_count() == 7 && store::entry_count() == 7);
    var same = true;
    for i in 7 {
        let want = if i == 3 { remove("e3", 100) } else { sample_body(i + 7 * ((199 - i) / 7)) };
        if body_of(str("e", i)) != want { same = false; }
    }
    expect("compact keeps the newest body of each entry, a remove too", same);
    var after: u8[>..] = [];
    listed_ids(after, store::newest_first());
    expect("compact keeps the order", after == before);
    expect(str("compact makes the segment smaller: ", size_before, " to ", store::segment_size(), " bytes"), store::segment_size() < size_before / 20);
    let s, rev = store::append(put("e3", 100, "2026-10-28", "x"));
    expect("after compact, the rule holds", is(s, store::Status.Conflict) && rev == 100);
    let s2, rev2 = store::append(put("e3", 101, "2026-10-28", "back"));
    expect("after compact, appends work", is(s2, store::Status.Created));
    expect("a reader after the compaction sees the new segment", store::open(dir, false) && body_of("e3") == put("e3", 101, "2026-10-28", "back") && store::record_count() == 8);
    store::close();
}

// The bodies at the top rev of the entry id: its siblings, then the entry,
// each with a newline.
fn tops(id: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    let e = store::get(id);
    guard e else { return out; }
    store::each_top(e) { t => format(out, store::body(t), "\n"); };
    return out;
}

// Signed records, and the rule of a merge: siblings at the same rev.
fn test_signed() {
    let dir = fresh("signed");
    guard store::open(dir, true) else { abort("cannot open"); }
    let sig = "MEUCIQDsig+/=";
    let p1 = put("s1", 1, "2026-10-28", "b");
    var s, rev = store::merge(p1, sig);
    let e = store::get("s1");
    expect("a signed body is saved, with its signature beside it", is(s, store::Status.Created) && e && store::body(e) == p1 && store::signature(e) == sig);
    s, rev = store::merge(put("s2", 1, "2026-10-28", "x"), "not base64\n");
    expect("a signature that is not base64 is refused", is(s, store::Status.Invalid));
    s, rev = store::append(put("s1", 1, "2026-10-28", "c"));
    expect("an append at the same rev is refused, also with a body that sorts later", is(s, store::Status.Conflict) && tops("s1") == str(p1, "\n"));
    let p1a = put("s1", 1, "2026-10-28", "a");
    s, rev = store::merge(p1a, sig);
    let e1 = store::get("s1");
    expect("a merge of another body at the same rev keeps both: the one that sorts last is the entry",
           is(s, store::Status.Created) && rev == 1 && body_of("s1") == p1 && e1 && store::conflicted(e1) && tops("s1") == str(p1a, "\n", p1, "\n"));
    let p1c = put("s1", 1, "2026-10-28", "c");
    s, rev = store::merge(p1c, sig);
    let three = str(p1a, "\n", p1, "\n", p1c, "\n");
    expect("a third body at the same rev is a sibling too, and sorts last", is(s, store::Status.Created) && body_of("s1") == p1c && tops("s1") == three);
    s, rev = store::merge(p1a, "b3RoZXI=");
    let sa, ra = store::merge(p1c, "b3RoZXI=");
    expect("a merge of a body that the store has at the top rev, with another signature, changes nothing",
           is(s, store::Status.Same) && is(sa, store::Status.Same) && store::record_count() == 3);
    store::merge(put("r1", 1, "2026-10-27", "x"), sig);
    s, rev = store::merge(remove("r1", 1), sig);
    var ids: u8[>..] = [];
    listed_ids(ids, store::newest_first());
    expect("a remove at the same rev as a put is a sibling; it sorts last, so the entry is not listed, and the put stays",
           is(s, store::Status.Created) && ids == "s1" && tops("r1") == str(put("r1", 1, "2026-10-27", "x"), "\n", remove("r1", 1), "\n"));
    let reopened = store::open(dir, false);
    let r1 = store::get("r1");
    expect("a reader indexes the siblings", reopened && tops("s1") == three && sig_of("s1") == sig && r1 && store::conflicted(r1));
    expect("a compaction keeps each sibling", store::open(dir, true) && store::compact() && store::record_count() == 5 && tops("s1") == three && sig_of("s1") == sig);
    let p2 = put("s1", 2, "2026-10-28", "a");
    s, rev = store::merge(p2, sig);
    let e2 = store::get("s1");
    expect("a pick at rev + 1 replaces all the siblings", is(s, store::Status.Created) && rev == 1 && e2 && !store::conflicted(e2) && tops("s1") == str(p2, "\n"));
    var records: u8[>..] = [];
    if e2 { records.append(store::record(e2)); }
    s, rev = store::merge(p1c, sig);
    expect("a merge of a lower rev is refused", is(s, store::Status.Conflict) && rev == 2);
    var got: u8[>..] = [];
    var count = 0;
    let whole = store::each_in(records) { g, b => got.append(b); count++; };
    expect("the record of an entry reads back as its signature and body", whole && count == 1 && got == p2);
    records[20] ^= 1;
    expect("a changed byte in a record from a peer is found", !store::each_in(records) { g, b => {} });
    expect("after a pick, a reader has no siblings", store::open(dir, false) && tops("s1") == str(p2, "\n") && sig_of("s1") == sig);
    expect("after a pick, a compaction drops the old siblings", store::open(dir, true) && store::compact() && store::record_count() == 3 && tops("s1") == str(p2, "\n"));
    store::close();
}

// The race: writers in threads, each with the store open on its own, and
// readers that refresh while the writers write.
struct Done { created: i64 }
struct Seen { refreshes: i64, faults: i64 }
struct Stop { now: bool }

let IDS = 10;

thread_fn writer_thread(dir: u8[..1024], name: i64, n: i64) {
    guard store::open(dir, true) else { abort("cannot open"); }
    var r = rng { name as! u64 + 1 };
    var seen: i64[>..] = [];
    push_n(seen, 0, IDS);
    var created = 0;
    for k in n {
        let i = r.rand_int(IDS);
        let s, rev = store::append(put(str("e", i), seen[i] + 1, "2026-10-28", str("writer ", name, " change ", k)));
        if store::status_text(s) == "created" { created++; seen[i] += 1; }
        else if store::status_text(s) == "conflict" { seen[i] = rev; }
        else { abort(str("append: ", store::status_text(s))); }
    }
    qput(Done { created: created });
}

thread_fn reader_thread(dir: u8[..1024]) {
    guard store::open(dir, false) else { abort("cannot open"); }
    var last: i64[>..] = [];
    push_n(last, 0, IDS);
    var refreshes = 0;
    var faults = 0;
    loop {
        let stop, got = qpoll<Stop>();
        if got { break; }
        if !store::refresh() { faults++; }
        refreshes++;
        for i in IDS {
            let e = store::get(str("e", i));
            guard e else { continue; }
            if e.rev < last[i] { faults++; }
            last[i] = e.rev;
            if find(store::body(e), str("\"rev\":", e.rev, ",")) < 0 { faults++; }
        }
    }
    qput(Seen { refreshes: refreshes, faults: faults });
}

fn test_threads() {
    let dir = fresh("threads");
    var d: u8[..1024] = [];
    d.append(dir);
    let writers = 8;
    let each = 150;
    let readers = 2;
    let t0 = clock_ns();
    var ids: i64[>..] = [];
    for k in readers { ids.push(thread_spawn(reader_thread, d)); }
    var wids: i64[>..] = [];
    for k in writers { wids.push(thread_spawn(writer_thread, d, k, each)); }
    var created = 0;
    for k in writers { created += qget<Done>().created; }
    let ms = (clock_ns() - t0) / 1000000;
    for k in readers { qput(Stop { now: true }); }
    var refreshes = 0;
    var faults = 0;
    for k in readers {
        let seen = qget<Seen>();
        refreshes += seen.refreshes;
        faults += seen.faults;
    }
    for id in wids { thread_wait(id); }
    for id in ids { thread_wait(id); }
    guard store::open(dir, false) else { abort("cannot open"); }
    var back = false;
    var count: i64[>..] = [];
    push_n(count, 0, IDS);
    store::each_record() { body =>
        let at = find(body, "\"id\":\"e") + 7;
        let i = (body[at] - '0') as i64;
        let rev_at = find(body, "\"rev\":") + 6;
        let rev, ok = parse_int(body[rev_at..rev_at + find(body[rev_at..], ",")]);
        if rev != count[i] + 1 { back = true; }
        count[i] = rev;
    };
    print("note: ", writers, " writer threads, ", writers * each, " appends, ", created, " created, ", ms, " ms; ",
          readers, " reader threads, ", refreshes, " refreshes");
    expect("each created change is in the segment once", store::record_count() == created);
    expect("the revs of each entry go 1, 2, 3 in the segment: no rev goes back, and none is lost", !back);
    expect("the readers never saw a rev go back, or a body that is not its rev", faults == 0);
    store::close();
}

fn test_speed() {
    let dir = fresh("speed");
    var ends: i64[>..] = [];
    let t0 = clock_ns();
    sample(dir, 2000, ends);
    let append_us = (clock_ns() - t0) / 1000 / 2000;
    let t1 = clock_ns();
    let rounds = 100;
    for k in rounds { store::open(dir, false); }
    let open_us = (clock_ns() - t1) / 1000 / rounds;
    let t2 = clock_ns();
    var n = 0;
    for k in rounds {
        store::refresh();
        for i in store::newest_first() { n += store::body(store::entry(i)).len; }
    }
    let list_us = (clock_ns() - t2) / 1000 / rounds;
    print("note: 2000 records: ", append_us, " us an append (with the fsync), ", open_us, " us an open, ",
          list_us, " us a refresh and a walk of the list");
    expect("the speed test read the bodies", n > 0);
    store::close();
}

fn main() {
    let a = args();
    guard a.len == 2 else { abort("usage: store_test <empty work directory>"); }
    work.append(a[1]);
    test_rules();
    test_torn();
    test_corrupt();
    test_compact();
    test_signed();
    test_threads();
    test_speed();
    if fails == 0 { print("all pass"); } else { print(fails, " failed"); exit(1); }
}
