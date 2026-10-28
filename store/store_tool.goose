// A command-line tool over the store, for the tests in test.sh: the writer
// process that the crash tests kill, and the check after each crash.
// build.sh builds it with STORE_FAULTS, so it is a test tool only.
//
//   store_tool <dir> append-file <bodies> <from>   append each line from line <from>
//   store_tool <dir> hammer <ids> <n> <name>       n appends that race other writers
//   store_tool <dir> compact
//   store_tool <dir> check                         counts, torn bytes and damage
//   store_tool <dir> verify <bodies> <acked>       the store against a model of the lines
//   store_tool <dir> revs                          fails if a rev of an id goes back

import std;
import os;
import dictionary;
import store;

fn say(line: u8[:]) {
    write_stdout(line);
    write_stdout("\n");
    flush_stdout();
}

fn fail(why: u8[:]) {
    write_stderr(str("store_tool: ", why, "\n"));
    exit(1);
}

fn lines_of(path: u8[:], text: u8[>..]&) -> const u8[:][>..] {
    guard read_file(path, text) else { fail(str("cannot read ", path)); }
    var out: const u8[:][>..] = [];
    each_split(text, '\n') { if it.len > 0 { out.push(it); } };
    return out;
}

// Appends the lines from line from on, and prints "<line> <status>" when
// each append is done. A line the harness sees is acknowledged.
fn append_file(path: u8[:], from: i64) {
    var text: u8[>..] = [];
    let lines = lines_of(path, text);
    for line, k in lines {
        guard k >= from else { continue; }
        let status, rev = store::append(line);
        match status {
            Failed => fail(str("append failed at line ", k)),
            _ => {},
        }
        say(str(k, " ", store::status_text(status)));
    }
}

// n appends to ids e0..e<ids-1>, each with the rev after the one this writer
// saw last, as the phone's outbox does after a 409.
fn hammer(ids: i64, n: i64, name: u8[:]) {
    var r = rng { hash(name) };
    var seen: i64[>..] = [];
    push_n(seen, 0, ids);
    var created = 0;
    for k in n {
        let i = r.rand_int(ids);
        let body = str("{\"entry\":{\"date\":\"2026-10-28\",\"title\":\"", name, " ", k,
                       "\"},\"id\":\"e", i, "\",\"key\":\"phone\",\"op\":\"put\",\"rev\":", seen[i] + 1, ",\"v\":1}");
        let status, rev = store::append(body);
        match status {
            Created => { created++; seen[i] += 1; },
            Conflict => { seen[i] = rev; },
            _ => fail(str("append: ", store::status_text(status))),
        }
    }
    say(str(name, " created ", created));
}

fn check() {
    say(str("records ", store::record_count(), " entries ", store::entry_count(),
            " torn ", store::torn_bytes(), " damage ", store::damage_list().len));
}

// The rule of docs/protocol.md, on its own, for the model.
struct Model { rev: i64, line: i64 }

fn id_rev(line: u8[:]) -> u8[:], i64 {
    let i = find(line, "\"id\":\"");
    let r = find(line, "\"rev\":");
    guard i >= 0 && r >= 0 else { fail(str("no id or rev in ", line)); }
    let rest = line[i + 6..];
    let id = rest[..find(rest, "\"")];
    var rev = 0;
    for c in line[r + 6..] {
        guard c >= '0' && c <= '9' else { break; }
        rev = rev * 10 + (c - '0');
    }
    return id, rev;
}

fn model(lines: const u8[:][:], upto: i64) -> dictionary<const u8[:], Model> {
    var m = dictionary<const u8[:], Model> {};
    for k in min(upto, lines.len) {
        let id, rev = id_rev(lines[k]);
        let have = m.get(id);
        if have {
            guard lines[have.line] != lines[k] && rev > have.rev else { continue; }
        }
        m.insert(id, Model { rev: rev, line: k });
    }
    return m;
}

// The store holds the model after the acknowledged lines, or after one line
// more (the line that was in flight at the crash, if it got to the disk).
// Each record is one of the lines, whole, and no rev of an id goes back.
fn verify(path: u8[:], acked: i64) {
    var text: u8[>..] = [];
    let lines = lines_of(path, text);
    var faults = 0;
    if store::torn_bytes() > 0 { say(str("note: ", store::torn_bytes(), " torn bytes at the end, not served")); }
    if store::damage_list().len > 0 { say("FAIL: damage in the segment"); faults++; }
    var whole = dictionary<const u8[:], bool> {};
    for line in lines { whole.insert(line, true); }
    store::each_record() { body =>
        if !whole.contains(body) { say(str("FAIL: a record that is not a line: ", body)); faults++; }
    };
    var matched = false;
    for upto in [acked, acked + 1] {
        var m = model(lines, upto);
        var same = m.count == store::entry_count();
        m.each() { id, want =>
            let e = store::get(id);
            if !e || store::body(e) != lines[want.line] { same = false; }
        };
        if same { matched = true; }
    }
    if !matched { say(str("FAIL: the store is not the model after line ", acked, " or ", acked + 1)); faults++; }
    if revs_go_back() { faults++; }
    if faults > 0 { exit(1); }
    say("ok");
}

fn revs_go_back() -> bool {
    var last = dictionary<u8[..64], i64> {};
    var back = false;
    store::each_record() { body =>
        let id, rev = id_rev(body);
        var key: u8[..64] = [];
        key.append(id);
        let have = last.get(key);
        if have && rev <= have { say(str("FAIL: rev ", rev, " of ", id, " after rev ", have)); back = true; }
        last.insert(key, rev);
    };
    return back;
}

fn number(s: u8[:]) -> i64 {
    let n, ok = parse_int(s);
    guard ok else { fail(str("not a number: ", s)); }
    return n;
}

fn main() {
    let a = args();
    guard a.len >= 3 else { fail("usage: store_tool <dir> <command> ..."); }
    let command = a[2];
    let write = command == "append-file" || command == "hammer" || command == "compact";
    guard store::open(a[1], write) else { fail(str("cannot open the store in ", a[1])); }
    if command == "append-file" && a.len == 5 { append_file(a[3], number(a[4])); }
    else if command == "hammer" && a.len == 6 { hammer(number(a[3]), number(a[4]), a[5]); }
    else if command == "compact" { if !store::compact() { fail("compact failed"); } }
    else if command == "check" { check(); }
    else if command == "verify" && a.len == 5 { verify(a[3], number(a[4])); }
    else if command == "revs" { if revs_go_back() { exit(1); } say("ok"); }
    else { fail(str("unknown command ", command)); }
}
