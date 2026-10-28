// pond_node: the long-running daemon of the Pond store, one on each node.
// This is phase 2 of docs/store.md: shadow mode. pond_save and the files in
// entries/ stay the source of truth. The daemon takes each entry file that
// has a good phone signature into its own store, and serves the same pages
// as pond_read from the store: GET /pond/entries.json, /log/ and
// /log/feed.xml. pond_shadow compare finds each difference.
//
//   pond_node --pond <dir> --store <dir> --template <file> --port <n> [--wireguard <address>]
//
// It listens on 127.0.0.1 and on the WireGuard address, and on no other
// address. A connection speaks FastCGI, from httpd. The daemon closes a
// connection that does not.
//
// The threads: main accepts the connections and puts each on the queue for
// Conn; the readers take them, each with the store open on its own; one
// writer reads the entry files into the store once each second.

import std;
import os;
import json;
import base64;
import dictionary;
import store from "../store";
import render;

// pond_net.h: the sockets.
extern fn pond_no_sigpipe();
extern fn pond_listen(host: const u8[:], port: i32) -> i32;
extern fn pond_bound_port(fd: i32) -> i32;
extern fn pond_accept(a: i32, b: i32) -> i32;
extern fn pond_recv(fd: i32, max: i64, out: u8[>..]&) -> i64;
extern fn pond_send(fd: i32, data: const u8[:]) -> bool;
extern fn pond_close(fd: i32);
// pond_node.h: unveil and pledge on OpenBSD.
extern fn pond_node_sandbox(pond: const u8[:], store: const u8[:], template: const u8[:]) -> bool;
// pond_read.h: the time of the last change of a file, in nanoseconds.
extern fn pond_mtime_ns(path: const u8[:]) -> i64;
// pond_verify.h: ECDSA P-256 with SHA-256, through libcrypto.
extern fn pond_verify_p256(pub_der: const u8[:], msg: const u8[:], sig_der: const u8[:]) -> bool;

struct Config { pond: u8[..1024], store: u8[..1024], template: u8[..1024] }
struct Conn { fd: i32 }

let SCAN_MS = 1000;
let MAX_REQUEST = 65536;
// A full queue turns a connection away, so that a flood cannot use all the memory.
let MAX_WAITING = 1024;

fn log(line: u8[:]) {
    write_stderr(str("pond_node: ", line, "\n"));
}

fn die(why: u8[:]) {
    log(why);
    exit(1);
}

// The writer: entry files into the store.

// What the writer saw of an entry file and its signature at its last read.
struct Seen { body: i64, sig: i64 }

struct Change { name: u8[..80], at: i64, seen: Seen }

// True if body has a good signature, in sig_text, from a key in keys/.
fn signed(c: Config&, body: u8[:], sig_text: u8[:]) -> bool {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(body, doc, decoded);
    let key, key_ok = json::as_string(json::member(root, "key"));
    guard key_ok && store::is_name(key) else { return false; }
    var sig: u8[>..] = [];
    var pub_text: u8[>..] = [];
    var pub: u8[>..] = [];
    return base64::decode(sig, trim(sig_text))
        && read_file(str(c.pond, "/keys/", key, ".pub"), pub_text)
        && base64::decode(pub, trim(pub_text))
        && pond_verify_p256(pub, body, sig);
}

// Takes one entry file into the store. False if it must be read again at
// the next scan.
fn take(c: Config&, name: u8[:]) -> bool {
    let base = name[..name.len - 5];
    var body: u8[>..] = [];
    var sig_text: u8[>..] = [];
    guard read_file(str(c.pond, "/entries/", name), body) else { return false; }
    read_file(str(c.pond, "/entries/", base, ".sig"), sig_text);
    var id: u8[>..] = [];
    id.append(base);
    let e = store::get(id);
    if e && store::body(e) == body { return true; }
    guard signed(c, body, sig_text) else { log(str("refused ", name, ": no good signature from a key in keys/")); return true; }
    let status, rev = store::append(body);
    match status {
        Created => log(str("took ", name)),
        Same => {},
        Conflict => log(str("refused ", name, ": the store has rev ", rev)),
        Invalid => log(str("refused ", name, ": not a valid body")),
        Failed => { log(str("cannot save ", name, " in the store")); return false; },
    }
    return true;
}

// Takes each entry file that changed since the last scan, in the order of
// the changes, so that the store lists the entries of one date in the same
// order as pond_read.
fn scan(c: Config&, seen: dictionary<u8[..80], Seen>&) {
    let dir = str(c.pond, "/entries");
    var names: u8[>..] = [];
    guard list_dir(dir, names) else { log(str("cannot list ", dir)); return; }
    var changes: Change[>..] = [];
    each_split(names, '\n') {
        guard ends_with(it, ".json") && it.len <= 80;
        let now = Seen {
            body: pond_mtime_ns(str(dir, "/", it)),
            sig: pond_mtime_ns(str(dir, "/", it[..it.len - 5], ".sig")),
        };
        var name: u8[..80] = [];
        name.append(it);
        let was = ::get(seen, name);
        guard !was || was.body != now.body || was.sig != now.sig;
        changes.push(Change { name: name, at: now.body, seen: now });
    };
    // Files with the same time (on OpenBSD, the time has the resolution of
    // a tick of the clock) go in the reverse order of their names, so that
    // the newest first list has them in the order of their names, as
    // pond_read has them.
    sort(changes) { a, b => a.at < b.at || (a.at == b.at && compare(a.name[..], b.name[..]) > 0) };
    for ch in changes {
        if take(c, ch.name) { seen.insert(ch.name, ch.seen); }
    }
}

thread_fn writer(c: Config) {
    guard store::open(c.store, true) else { die("the writer cannot open the store"); }
    var seen = dictionary<u8[..80], Seen> {};
    loop {
        scan(c, seen);
        sleep_ms(SCAN_MS);
    }
}

// The readers: one request on each connection.

struct Request { id: i64, method: u8[..16], uri: u8[..4096] }

fn be16(s: u8[:], at: i64) -> i64 { ((s[at] as i64) << 8) | s[at + 1] }

// A FastCGI name or value length: 1 byte, or 4 bytes with the top bit set.
fn fcgi_length(s: u8[:], at: i64&) -> i64 {
    guard at < s.len else { return -1; }
    if s[at] < 128 { at += 1; return s[at - 1]; }
    guard at + 4 <= s.len else { return -1; }
    let n = (((s[at] & 127) as i64) << 24) | ((s[at + 1] as i64) << 16) | ((s[at + 2] as i64) << 8) | s[at + 3];
    at += 4;
    return n;
}

// The FastCGI request in buf: the records BEGIN_REQUEST, PARAMS up to an
// empty one, and STDIN up to an empty one. 0 if buf has only a part of it,
// -1 if it is not valid, else 1.
fn fcgi_parse(buf: u8[:], r: Request&) -> i64 {
    var params: u8[>..] = [];
    var params_done = false;
    var at = 0;
    loop {
        guard at + 8 <= buf.len else { return 0; }
        let kind = buf[at + 1];
        let n = be16(buf, at + 4);
        let end = at + 8 + n + buf[at + 6];
        guard buf[at] == 1 else { return -1; }
        guard end <= buf.len else { return 0; }
        let content = buf[at + 8..at + 8 + n];
        if kind == 1 { r.id = be16(buf, at + 2); }
        else if kind == 4 {
            if n == 0 { params_done = true; } else { params.append(content); }
        } else if kind == 5 && n == 0 {
            guard params_done else { return -1; }
            break;
        }
        at = end;
    }
    var p = 0;
    while p < params.len {
        let nn = fcgi_length(params, p);
        let vn = fcgi_length(params, p);
        guard nn >= 0 && vn >= 0 && p + nn + vn <= params.len else { return -1; }
        let name = params[p..p + nn];
        let value = params[p + nn..p + nn + vn];
        if name == "REQUEST_METHOD" && value.len <= 16 { r.method.append(value); }
        else if name == "REQUEST_URI" && value.len <= 4096 { r.uri.append(value); }
        p += nn + vn;
    }
    return 1;
}

fn read_request(fd: i32, r: Request&) -> bool {
    var buf: u8[>..] = [];
    loop {
        guard pond_recv(fd, MAX_REQUEST - buf.len, buf) > 0 else { return false; }
        r.method.clear();
        r.uri.clear();
        let got = fcgi_parse(buf, r);
        if got != 0 { return got > 0; }
        guard buf.len < MAX_REQUEST else { return false; }
    }
}

fn put_record(out: u8[>..]&, kind: u8, id: i64, content: u8[:]) {
    out.push(1);
    out.push(kind);
    out.push(((id >> 8) & 255) as! u8);
    out.push((id & 255) as! u8);
    out.push(((content.len >> 8) & 255) as! u8);
    out.push((content.len & 255) as! u8);
    out.push(0);
    out.push(0);
    out.append(content);
}

// The CGI reply as FastCGI records: STDOUT up to an empty one, then
// END_REQUEST, which says that the request is complete.
fn fcgi_reply(out: u8[>..]&, id: i64, cgi: u8[:]) {
    var at = 0;
    while at < cgi.len {
        let n = min(cgi.len - at, 32768);
        put_record(out, 6, id, cgi[at..at + n]);
        at += n;
    }
    put_record(out, 6, id, "");
    put_record(out, 3, id, [0, 0, 0, 0, 0, 0, 0, 0]);
}

// The items of the store, newest first, made again only after the store
// changes.
struct View { records: i64, size: i64, items: render::Item[>..] }

fn update(v: View&) {
    guard store::refresh() else { log("a reader cannot read the store"); return; }
    guard store::record_count() != v.records || store::segment_size() != v.size else { return; }
    v.items.clear();
    for i in store::newest_first() {
        let item, ok = render::item_of(store::body(store::entry(i)), 0);
        if ok { v.items.push(copy(item)); }
    }
    v.records = store::record_count();
    v.size = store::segment_size();
}

fn serve(c: Config&, fd: i32, v: View&) {
    var r = Request { id: 0, method: [], uri: [] };
    guard read_request(fd, r) else { pond_close(fd); return; }
    update(v);
    var order: render::Item&[>..] = [];
    for it in v.items { order.push(it); }
    var cgi: u8[>..] = [];
    render::reply(cgi, r.method, r.uri, c.template, order);
    var out: u8[>..] = [];
    fcgi_reply(out, r.id, cgi);
    pond_send(fd, out);
    pond_close(fd);
}

thread_fn reader(c: Config) {
    guard store::open(c.store, false) else { die("a reader cannot open the store"); }
    var v = View { records: -1, size: -1, items: [] };
    loop { serve(c, qget<Conn>().fd, v); }
}

fn main() {
    let a = args();
    var c = Config { pond: [], store: [], template: [] };
    var port: i64 = -1;
    var wireguard: u8[>..] = [];
    var k = 1;
    while k + 1 < a.len {
        let v = a[k + 1];
        guard v.len < 1024 else { die(str(a[k], " is too long")); }
        if a[k] == "--pond" { c.pond.append(v); }
        else if a[k] == "--store" { c.store.append(v); }
        else if a[k] == "--template" { c.template.append(v); }
        else if a[k] == "--wireguard" { wireguard.append(v); }
        else if a[k] == "--port" {
            let n, ok = parse_int(v);
            guard ok && n >= 0 && n <= 65535 else { die("--port needs 0 to 65535"); }
            port = n;
        } else { break; }
        k += 2;
    }
    guard k == a.len && c.pond.len > 0 && c.store.len > 0 && c.template.len > 0 && port >= 0 else {
        die("usage: pond_node --pond <dir> --store <dir> --template <file> --port <n> [--wireguard <address>]");
    }

    pond_no_sigpipe();
    let local = pond_listen("127.0.0.1", port as! i32);
    guard local >= 0 else { die(str("cannot listen on 127.0.0.1 port ", port)); }
    let bound = pond_bound_port(local);
    var wg: i32 = -1;
    if wireguard.len > 0 {
        wg = pond_listen(wireguard, bound);
        guard wg >= 0 else { die(str("cannot listen on ", wireguard, " port ", bound, ": it must be a numeric address, and not 0.0.0.0 or ::")); }
    }

    // The writer open makes the store or recovers it after a crash. The
    // first scan reads all the entry files before the daemon serves, so
    // that it does not serve a part of the log. Each thread then opens the
    // store on its own: a thread gets a copy of the globals of the store.
    make_dir(c.store);
    guard store::open(c.store, true) else { die(str("cannot open the store in ", c.store)); }
    var seen = dictionary<u8[..80], Seen> {};
    scan(c, seen);
    log(str("the store has ", store::entry_count(), " entries"));
    store::close();

    let readers = max(2, hardware_threads());
    guard pond_node_sandbox(c.pond, c.store, c.template) else { die("no sandbox"); }
    qlimit<Conn>(MAX_WAITING);
    thread_spawn(writer, c);
    for i in readers { thread_spawn(reader, c); }
    print("listening on 127.0.0.1 port ", bound);
    if wg >= 0 { print("listening on ", wireguard, " port ", bound); }
    flush_stdout();

    loop {
        let fd = pond_accept(local, wg);
        if fd < 0 { sleep_ms(10); continue; }
        if !qput(Conn { fd: fd }) { pond_close(fd); }
    }
}
