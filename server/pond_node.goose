// pond_node: the long-running daemon of the Pond store, one on each node.
// Phase 2 of docs/store.md is shadow mode. pond_save and the files in
// entries/ stay the source of truth. The daemon takes each entry file that
// has a good phone signature into its own store, and serves the same pages
// as pond_read from the store: GET /pond/entries.json, /log, /log/ and
// /log/feed.xml. pond_shadow compare finds each difference.
// Phase 3 is the sync: each node pulls the revisions that it does not have
// from its peers (POST /pond/sync), and GET /pond/node gives the number of
// entries and the index hash.
//
//   pond_node --pond <dir> --store <dir> --template <file> --port <n> [--wireguard <address>]
//             [--node <name> --node-key <file> --peer <address>:<port> ...]
//
// It listens on 127.0.0.1 and on the WireGuard address, and on no other
// address. A connection speaks FastCGI, from httpd or from a peer. The
// daemon closes a connection that does not.
//
// The threads: main accepts the connections and puts each on the queue for
// Conn; the readers take them, each with the store open on its own; one
// writer reads the entry files into the store once each second, and takes
// the bodies that the syncer pulled from the peers.

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
extern fn pond_connect(host: const u8[:], port: i32) -> i32;
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
// pond_sync.h: the node signature and SHA-256.
extern fn pond_sign_p256(key_pem: const u8[:], msg: const u8[:], out: u8[>..]&) -> bool;
extern fn pond_sha256(msg: const u8[:], out: u8[>..]&) -> bool;

struct Peer { host: u8[..64], port: i32 }

// node and key (the private node key, in PEM) are empty if the node does
// not sync.
struct Config {
    pond: u8[..1024], store: u8[..1024], template: u8[..1024],
    node: u8[..64], key: u8[..1024], peers: Peer[..8],
}
struct Conn { fd: i32 }

let SCAN_MS = 1000;
// A pull from each peer each 5 s: a partition heals well within 60 s.
let SYNC_MS = 5000;
// The ids in one request for bodies: 100 bodies are 1 MB or less.
let BATCH = 100;
// The largest reply that a pull reads: an index list of 50,000 entries is
// about 2 MB.
let MAX_REPLY = 16 << 20;
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
    let status, rev = store::merge(body, trim(sig_text));
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

// A body that the syncer pulled from a peer, with a good phone signature.
// end marks the end of a batch: the writer then sends Merged.
struct Pulled { sig: u8[..255], body: u8[..8192], end: bool }
struct Merged { took: i64 }

thread_fn writer(c: Config) {
    guard store::open(c.store, true) else { die("the writer cannot open the store"); }
    var seen = dictionary<u8[..80], Seen> {};
    var took = 0;
    loop {
        scan(c, seen);
        // Between two scans, the writer takes the pulled bodies.
        let until = clock_ns() + SCAN_MS * 1000000;
        loop {
            let left = (until - clock_ns()) / 1000000;
            guard left > 0 else { break; }
            let p, ok = qget<Pulled>(left);
            guard ok else { break; }
            if p.end {
                qput(Merged { took: took });
                took = 0;
                continue;
            }
            let status, rev = store::merge(p.body, p.sig);
            match status {
                Created => { took++; },
                Failed => log("cannot save a pulled body in the store"),
                _ => {},
            }
        }
    }
}

// The sync.

fn hex(out: u8[>..]&, bytes: u8[:]) {
    let digits = "0123456789abcdef";
    for b in bytes {
        out.push(digits[b >> 4]);
        out.push(digits[b & 15]);
    }
}

// The index hash: the SHA-256 of the newest revision of each entry, a
// remove too, and of each sibling, in the order of the ids, then of the
// bodies, as "<id> <rev> <length>\n<body>". Two nodes with the same hash
// have the same bodies.
fn index_hash() -> u8[>..] {
    var ids: i64[>..] = [];
    for i in store::entry_count() { ids.push(i); }
    sort(ids) { a, b => compare(store::entry(a).id[..], store::entry(b).id[..]) < 0 };
    var text: u8[>..] = [];
    for i in ids {
        store::each_top(store::entry(i)) { t =>
            format(text, t.id, " ", t.rev, " ", t.size, "\n");
            text.append(store::body(t));
        };
    }
    var h: u8[>..] = [];
    var out: u8[>..] = [];
    if pond_sha256(text, h) { hex(out, h); }
    return out;
}

fn body_crc(body: u8[:]) -> u32 { store::crc32c(0xFFFFFFFF, body) ^ 0xFFFFFFFF }

// True if body has a good signature, in sig_text, from the node key
// nodes/<node>.pub.
fn node_signed(c: Config&, node: u8[:], body: u8[:], sig_text: u8[:]) -> bool {
    guard store::is_name(node) else { return false; }
    var sig: u8[>..] = [];
    var pub_text: u8[>..] = [];
    var pub: u8[>..] = [];
    return base64::decode(sig, trim(sig_text))
        && read_file(str(c.pond, "/nodes/", node, ".pub"), pub_text)
        && base64::decode(pub, trim(pub_text))
        && pond_verify_p256(pub, body, sig);
}

// The reply to POST /pond/sync. The body is lines: the kind, the name of
// the node that asks, then the lines of the kind. The Signature is from the
// node key of that node.
//   index <node> <hash>: the index hash, then, if the hash is not the one
//     of the node that asks, "<id> <rev> <crc>" for each entry and each
//     sibling, in the order of the changes. crc is the CRC-32C of the body.
//   bodies <node> <id>...: the record of the newest revision of each id,
//     and of each sibling, that the store has with a phone signature, as in
//     the segment.
fn sync_reply(c: Config&, r: Request&, out: u8[>..]&) {
    guard r.method == "POST" else { render::format_reply(out, "405 Method Not Allowed", "text/plain", "use POST\n"); return; }
    let lines = split(r.body, '\n');
    guard lines.len >= 3 && node_signed(c, lines[1], r.body, r.sig) else {
        render::format_reply(out, "403 Forbidden", "text/plain", "no good signature from a node key\n");
        return;
    }
    var body: u8[>..] = [];
    if lines[0] == "index" {
        let hash = index_hash();
        format(body, hash, "\n");
        if lines[2] != hash[..] {
            var ids: i64[>..] = [];
            for i in store::entry_count() { ids.push(i); }
            sort(ids) { a, b => store::entry(a).seq < store::entry(b).seq };
            for i in ids {
                store::each_top(store::entry(i)) { t => format(body, t.id, " ", t.rev, " ", body_crc(store::body(t)), "\n"); };
            }
        }
        render::format_reply(out, "200 OK", "text/plain", body);
    } else if lines[0] == "bodies" {
        for id in lines[2..] {
            let e = store::get(id);
            guard e else { continue; }
            store::each_top(e) { t => if t.sig_len > 0 { body.append(store::record(t)); } };
        }
        render::format_reply(out, "200 OK", "application/octet-stream", body);
    } else {
        render::format_reply(out, "400 Bad Request", "text/plain", "unknown kind\n");
    }
}

// A FastCGI name or value length: 1 byte, or 4 bytes with the top bit set.
fn put_length(out: u8[>..]&, n: i64) {
    if n < 128 { out.push(n as! u8); return; }
    out.append([(((n >> 24) & 127) | 128) as! u8, ((n >> 16) & 255) as! u8, ((n >> 8) & 255) as! u8, (n & 255) as! u8]);
}

fn put_param(out: u8[>..]&, name: u8[:], value: u8[:]) {
    put_length(out, name.len);
    put_length(out, value.len);
    out.append(name);
    out.append(value);
}

// The STDOUT of FastCGI records, or false if the records are not whole.
fn fcgi_stdout(rec: u8[:], out: u8[>..]&) -> bool {
    var at = 0;
    while at + 8 <= rec.len {
        let n = be16(rec, at + 4);
        let end = at + 8 + n + rec[at + 6];
        guard end <= rec.len else { return false; }
        if rec[at + 1] == 6 { out.append(rec[at + 8..at + 8 + n]); }
        if rec[at + 1] == 3 { return true; }
        at = end;
    }
    return false;
}

// Sends body, signed with the node key, to POST /pond/sync of the peer, and
// gives the body of a 200 reply. False if the peer did not give one.
fn call(c: Config&, p: Peer&, body: u8[:], out: u8[>..]&) -> bool {
    var der: u8[>..] = [];
    var sig: u8[>..] = [];
    guard pond_sign_p256(c.key, body, der) else { return false; }
    base64::encode(sig, der);
    var params: u8[>..] = [];
    put_param(params, "REQUEST_METHOD", "POST");
    put_param(params, "REQUEST_URI", "/pond/sync");
    put_param(params, "CONTENT_LENGTH", str(body.len));
    put_param(params, "HTTP_SIGNATURE", sig);
    var req: u8[>..] = [];
    put_record(req, 1, 1, [0, 1, 0, 0, 0, 0, 0, 0]);
    put_record(req, 4, 1, params);
    put_record(req, 4, 1, "");
    var at = 0;
    while at < body.len {
        let n = min(body.len - at, 32768);
        put_record(req, 5, 1, body[at..at + n]);
        at += n;
    }
    put_record(req, 5, 1, "");
    let fd = pond_connect(p.host, p.port);
    guard fd >= 0 else { return false; }
    var reply: u8[>..] = [];
    var ok = pond_send(fd, req);
    while ok && reply.len < MAX_REPLY {
        let n = pond_recv(fd, MAX_REPLY - reply.len, reply);
        guard n != 0 else { break; }
        ok = n > 0;
    }
    pond_close(fd);
    var cgi: u8[>..] = [];
    guard ok && fcgi_stdout(reply, cgi) && starts_with(cgi, "Status: 200") else { return false; }
    let k = find(cgi, "\r\n\r\n");
    guard k >= 0 else { return false; }
    out.append(cgi[k + 4..]);
    return true;
}

// Pulls from the peer p each revision that this store does not have, with
// a good phone signature, through the writer. The number of revisions that
// the writer took, or -1 if the peer did not reply. refused holds the
// "<id> <rev> <crc>" lines whose bodies had no good phone signature, so
// that the syncer does not pull them again.
fn pull(c: Config&, p: Peer&, refused: dictionary<u8[..96], bool>&) -> i64 {
    store::refresh();
    let mine = index_hash();
    var index: u8[>..] = [];
    guard call(c, p, str("index\n", c.node, "\n", mine, "\n"), index) else { return -1; }
    let lines = split(index, '\n');
    guard lines.len >= 1 && lines[0] != mine[..] else { return 0; }
    var wants: const u8[:][>..] = [];
    for line in lines[1..] {
        let f = split(line, ' ');
        guard f.len == 3 && line.len <= 96 else { continue; }
        let rev, rev_ok = parse_int(f[1]);
        let crc, crc_ok = parse_int(f[2]);
        guard rev_ok && crc_ok else { continue; }
        var key: u8[..96] = [];
        key.append(line);
        guard !refused.contains(key) else { continue; }
        guard wants.len == 0 || last(wants) != f[0] else { continue; }
        let e = store::get(f[0]);
        var have = false;
        if e && rev == e.rev { store::each_top(e) { t => if crc == body_crc(store::body(t)) { have = true; } }; }
        if !e || rev > e.rev || (rev == e.rev && !have) { wants.push(f[0]); }
    }
    var took = 0;
    var at = 0;
    while at < wants.len {
        var ask: u8[>..] = [];
        format(ask, "bodies\n", c.node);
        for id in wants[at..min(at + BATCH, wants.len)] { format(ask, "\n", id); }
        at += BATCH;
        var records: u8[>..] = [];
        guard call(c, p, ask, records) else { return -1; }
        let whole = store::each_in(records) { sig, body =>
            if signed(c, body, sig) {
                var q = Pulled { sig: [], body: [], end: false };
                q.sig.append(sig);
                q.body.append(body);
                qput(q);
            } else {
                var scratch: u8[>..] = [];
                let m, ok = store::meta(body, scratch);
                var key: u8[..96] = [];
                format(key, m.id, " ", m.rev, " ", body_crc(body));
                if !refused.contains(key) {
                    refused.insert(key, true);
                    log(str("refused ", m.id, " rev ", m.rev, " from ", p.host, ":", p.port, ": no good signature from a key in keys/"));
                }
            }
        };
        if !whole { log(str("refused the records from ", p.host, ":", p.port, ": not whole records")); }
        qput(Pulled { sig: [], body: [], end: true });
        let merged, ok = qget<Merged>(60000);
        guard ok else { return took; }
        took += merged.took;
    }
    return took;
}

thread_fn syncer(c: Config) {
    guard store::open(c.store, false) else { die("the syncer cannot open the store"); }
    var refused = dictionary<u8[..96], bool> {};
    var up: bool[8] = [true; 8];
    loop {
        for p, k in c.peers {
            let took = pull(c, p, refused);
            if took > 0 { log(str("took ", took, " revisions from ", p.host, ":", p.port)); }
            if (took >= 0) != up[k] {
                up[k] = took >= 0;
                log(str(if up[k] { "reached " } else { "cannot reach " }, p.host, ":", p.port));
            }
        }
        sleep_ms(SYNC_MS);
    }
}

// The readers: one request on each connection.

struct Request { id: i64, method: u8[..16], uri: u8[..4096], sig: u8[..512], body: u8[>..] }

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
        } else if kind == 5 {
            guard params_done else { return -1; }
            if n == 0 { break; }
            r.body.append(content);
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
        else if name == "HTTP_SIGNATURE" && value.len <= 512 { r.sig.append(value); }
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
        r.sig.clear();
        r.body.clear();
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

// The items of the store, newest first. update makes them, and the
// conflicts list, again only after the store changes.
struct View { records: i64, size: i64, items: render::Item[>..] }

fn update(v: View&, conflicts: u8[>..]&) {
    guard store::refresh() else { log("a reader cannot read the store"); return; }
    guard store::record_count() != v.records || store::segment_size() != v.size else { return; }
    v.items.clear();
    for i in store::newest_first() {
        let item, ok = render::item_of(store::body(store::entry(i)), 0);
        if ok { v.items.push(copy(item)); }
    }
    // Each entry with siblings, a removed one too, in the order of the ids:
    // {"id":...,"rev":n,"siblings":[...]}, with each body at the top rev.
    conflicts.clear();
    var ids: i64[>..] = [];
    for i in store::entry_count() { if store::conflicted(store::entry(i)) { ids.push(i); } }
    sort(ids) { a, b => compare(store::entry(a).id[..], store::entry(b).id[..]) < 0 };
    for i, k in ids {
        let e = store::entry(i);
        if k > 0 { conflicts.push(','); }
        conflicts.append("{\"id\":");
        json::format_string(conflicts, e.id);
        format(conflicts, ",\"rev\":", e.rev, ",\"siblings\":[");
        var first = true;
        store::each_top(e) { t =>
            if !first { conflicts.push(','); }
            first = false;
            render::format_sibling(conflicts, store::body(t));
        };
        conflicts.append("]}");
    }
    v.records = store::record_count();
    v.size = store::segment_size();
}

fn serve(c: Config&, fd: i32, v: View&, conflicts: u8[>..]&) {
    var r = Request { id: 0, method: [], uri: [], sig: [], body: [] };
    guard read_request(fd, r) else { pond_close(fd); return; }
    update(v, conflicts);
    var cgi: u8[>..] = [];
    if r.uri == "/pond/sync" {
        sync_reply(c, r, cgi);
    } else if r.uri == "/pond/node" && r.method == "GET" {
        render::format_reply(cgi, "200 OK", "application/json",
                             str("{\"entries\":", v.items.len, ",\"hash\":\"", index_hash(), "\"}\n"));
    } else {
        var order: render::Item&[>..] = [];
        for it in v.items { order.push(it); }
        render::reply(cgi, r.method, r.uri, c.template, order, conflicts);
    }
    var out: u8[>..] = [];
    fcgi_reply(out, r.id, cgi);
    pond_send(fd, out);
    pond_close(fd);
}

thread_fn reader(c: Config) {
    guard store::open(c.store, false) else { die("a reader cannot open the store"); }
    var v = View { records: -1, size: -1, items: [] };
    var conflicts: u8[>..] = [];
    loop { serve(c, qget<Conn>().fd, v, conflicts); }
}

fn main() {
    let a = args();
    var c = Config { pond: [], store: [], template: [], node: [], key: [], peers: [] };
    var port: i64 = -1;
    var wireguard: u8[>..] = [];
    var key_path: u8[>..] = [];
    var k = 1;
    while k + 1 < a.len {
        let v = a[k + 1];
        guard v.len < 1024 else { die(str(a[k], " is too long")); }
        if a[k] == "--pond" { c.pond.append(v); }
        else if a[k] == "--store" { c.store.append(v); }
        else if a[k] == "--template" { c.template.append(v); }
        else if a[k] == "--wireguard" { wireguard.append(v); }
        else if a[k] == "--node" {
            guard store::is_name(v) else { die("--node needs a name: 1 to 64 of A-Z a-z 0-9 -"); }
            c.node.append(v);
        }
        else if a[k] == "--node-key" { key_path.append(v); }
        else if a[k] == "--peer" {
            let colon = rfind(v, ":");
            let n, ok = parse_int(v[max(colon + 1, 0)..]);
            guard colon >= 1 && colon < 64 && ok && n >= 1 && n <= 65535 && c.peers.len < 8 else {
                die("--peer needs <numeric address>:<port>, at most 8 times");
            }
            var p = Peer { host: [], port: n as! i32 };
            p.host.append(v[..colon]);
            c.peers.push(p);
        }
        else if a[k] == "--port" {
            let n, ok = parse_int(v);
            guard ok && n >= 0 && n <= 65535 else { die("--port needs 0 to 65535"); }
            port = n;
        } else { break; }
        k += 2;
    }
    guard k == a.len && c.pond.len > 0 && c.store.len > 0 && c.template.len > 0 && port >= 0 else {
        die(str("usage: pond_node --pond <dir> --store <dir> --template <file> --port <n> [--wireguard <address>]\n",
                "                 [--node <name> --node-key <file> --peer <address>:<port> ...]"));
    }
    // The key is read before the sandbox hides it.
    guard c.peers.len == 0 || (c.node.len > 0 && key_path.len > 0) else { die("--peer needs --node and --node-key"); }
    if key_path.len > 0 {
        var pem: u8[>..] = [];
        guard read_file(key_path, pem) && pem.len < 1024 else { die(str("cannot read the node key ", key_path)); }
        c.key.append(pem);
        var test: u8[>..] = [];
        guard pond_sign_p256(c.key, "test", test) else { die(str("the node key ", key_path, " is not a P-256 private key in PEM")); }
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
    if c.peers.len > 0 { thread_spawn(syncer, c); }
    print("listening on 127.0.0.1 port ", bound);
    if wg >= 0 { print("listening on ", wireguard, " port ", bound); }
    flush_stdout();

    loop {
        let fd = pond_accept(local, wg);
        if fd < 0 { sleep_ms(10); continue; }
        if !qput(Conn { fd: fd }) { pond_close(fd); }
    }
}
