// pond_shadow: the tool for the shadow mode of pond_node (docs/store.md).
//
//   pond_shadow compare <pond_read> <pond dir> <template> <port>
//   pond_shadow get <fcgi|http> <port> <uri> [method]
//   pond_shadow bench <fcgi|http> <port> <uri> <clients> <requests>
//   pond_shadow bench cgi <pond_read> <pond dir> <template> <uri> <clients> <requests>
//
// compare gets each page from pond_read, and from pond_node on 127.0.0.1
// over FastCGI and over HTTP, and reports each difference. The exit status
// is 0 for no difference, 1 for a difference and 2 if a page did not come.
// get prints one reply of pond_node to a GET, or to another method. bench
// sends requests from <clients> threads at the same time, each <requests>
// in a sequence, and prints the throughput and the latency. cgi runs
// pond_read for each request, as slowcgi does.

import std;
import os;
import json;

// pond_net.h: the sockets. pond_spawn.h: a CGI program.
extern fn pond_no_sigpipe();
extern fn pond_connect(host: const u8[:], port: i32) -> i32;
extern fn pond_recv(fd: i32, max: i64, out: u8[>..]&) -> i64;
extern fn pond_send(fd: i32, data: const u8[:]) -> bool;
extern fn pond_close(fd: i32);
extern fn pond_run_cgi(program: const u8[:], env: const u8[:], out: u8[>..]&) -> bool;

let PAGES = ["/pond/entries.json", "/log/", "/log/feed.xml"];
// pond_node reads the entry files once each second.
let RETRY_MS = 2500;

fn fail(why: u8[:]) {
    write_stderr(str("pond_shadow: ", why, "\n"));
    exit(2);
}

// The target of a request: pond_node over FastCGI or HTTP, or pond_read.
struct Target { kind: u8[..8], port: i32, program: u8[..1024], pond: u8[..1024], template: u8[..1024] }

fn put_record(out: u8[>..]&, kind: u8, content: u8[:]) {
    out.append([1, kind, 0, 1, ((content.len >> 8) & 255) as! u8, (content.len & 255) as! u8, 0, 0]);
    out.append(content);
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
        let n = ((rec[at + 4] as i64) << 8) | rec[at + 5];
        let end = at + 8 + n + rec[at + 6];
        guard end <= rec.len else { return false; }
        if rec[at + 1] == 6 { out.append(rec[at + 8..at + 8 + n]); }
        if rec[at + 1] == 3 { return true; }
        at = end;
    }
    return false;
}

// An HTTP reply in the form of a CGI reply: the Status line, the other
// lines of the head but Content-Length and Connection, and the body.
fn cgi_of_http(reply: u8[:], out: u8[>..]&) -> bool {
    let head_end = find(reply, "\r\n\r\n");
    guard starts_with(reply, "HTTP/1.1 ") && head_end > 0 else { return false; }
    var first = true;
    each_split(reply[..head_end], '\n') {
        let line = trim(it);
        if first { format(out, "Status: ", line[9..], "\r\n"); first = false; }
        else if !starts_with(line, "Content-Length: ") && !starts_with(line, "Connection: ") { format(out, line, "\r\n"); }
    };
    out.append("\r\n");
    out.append(reply[head_end + 4..]);
    return true;
}

// One reply to GET uri, as a CGI reply. False if it did not come.
fn get(t: Target&, uri: u8[:], out: u8[>..]&) -> bool { return request(t, "GET", uri, out); }

fn request(t: Target&, method: u8[:], uri: u8[:], out: u8[>..]&) -> bool {
    if t.kind == "cgi" {
        let env = str("REQUEST_METHOD=GET\nREQUEST_URI=", uri, "\nPOND_DIR=", t.pond, "\nPOND_TEMPLATE=", t.template);
        return pond_run_cgi(t.program, env, out);
    }
    let fd = pond_connect("127.0.0.1", t.port);
    guard fd >= 0 else { return false; }
    var req: u8[>..] = [];
    if t.kind == "fcgi" {
        put_record(req, 1, [0, 1, 0, 0, 0, 0, 0, 0]);
        var params: u8[>..] = [];
        put_param(params, "REQUEST_METHOD", method);
        put_param(params, "REQUEST_URI", uri);
        put_record(req, 4, params);
        put_record(req, 4, "");
        put_record(req, 5, "");
    } else {
        format(req, method, " ", uri, " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    }
    var reply: u8[>..] = [];
    var ok = pond_send(fd, req);
    while ok {
        let n = pond_recv(fd, 1 << 20, reply);
        guard n != 0 else { break; }
        ok = n > 0;
    }
    pond_close(fd);
    guard ok else { return false; }
    return if t.kind == "fcgi" { fcgi_stdout(reply, out) } else { cgi_of_http(reply, out) };
}

fn target(kind: u8[:], port: i64) -> Target {
    var t = Target { kind: [], port: port as! i32, program: [], pond: [], template: [] };
    t.kind.append(kind);
    return t;
}

fn number(s: u8[:]) -> i64 {
    let n, ok = parse_int(s);
    guard ok && n >= 0 else { fail(str("not a number: ", s)); }
    return n;
}

// compare

// One entry of entries.json: its id and rev, and its place in the reply.
struct Element { id: u8[..64], rev: i64, at: i64, len: i64 }

// The entries of an entries.json reply, in their order. A string in JSON
// has its quotes escaped, so ',{"entry":' starts each entry after the first.
fn elements(reply: u8[:]) -> Element[>..] {
    var out: Element[>..] = [];
    let at = find(reply, "{\"entries\":[");
    guard at >= 0 else { return out; }
    var from = at + 12;
    while from < reply.len && reply[from] == '{' {
        let rest = reply[from..];
        var end = find(rest, ",{\"entry\":");
        let last = end < 0;
        if last { end = find(rest, "]}"); }
        guard end > 0 else { break; }
        let text = rest[..end];
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, err = json::parse(text, doc, decoded);
        let id, id_ok = json::as_string(json::member(root, "id"));
        let rev, rev_ok = json::as_i64(json::member(root, "rev"));
        var e = Element { id: [], rev: rev, at: from, len: end };
        if id.len <= 64 { e.id.append(id); }
        out.push(e);
        if last { break; }
        from += end + 1;
    }
    return out;
}

fn index_of(list: Element[:], id: u8[:]) -> i64 {
    for e, i in list { if e.id[..] == id { return i; } }
    return -1;
}

// The difference of the entries, one line for each entry.
fn report_entries(read: u8[:], node: u8[:], lines: u8[>..]&) {
    let a = elements(read);
    let b = elements(node);
    for e in a {
        let k = index_of(b, e.id);
        if k < 0 { format(lines, "  only pond_read has ", e.id, " rev ", e.rev, "\n"); }
        else if b[k].rev != e.rev { format(lines, "  ", e.id, ": rev ", e.rev, " in pond_read, rev ", b[k].rev, " in pond_node\n"); }
        else if node[b[k].at..b[k].at + b[k].len] != read[e.at..e.at + e.len] { format(lines, "  ", e.id, ": the fields differ\n"); }
    }
    for e in b {
        if index_of(a, e.id) < 0 { format(lines, "  only pond_node has ", e.id, " rev ", e.rev, "\n"); }
    }
    for e, i in a {
        guard i < b.len && b[i].id != e.id else { continue; }
        format(lines, "  the order differs at place ", i + 1, ": pond_read has ", e.id, ", pond_node has ", b[i].id, "\n");
        break;
    }
}

// The first line that differs.
fn report_lines(read: u8[:], node: u8[:], lines: u8[>..]&) {
    var a: u8[:][>..] = [];
    var b: u8[:][>..] = [];
    each_split(read, '\n') { a.push(it); };
    each_split(node, '\n') { b.push(it); };
    for i in max(a.len, b.len) {
        let x = if i < a.len { a[i] } else { "(no line)" };
        let y = if i < b.len { b[i] } else { "(no line)" };
        guard x != y else { continue; }
        format(lines, "  line ", i + 1, ": pond_read: ", x, "\n  line ", i + 1, ": pond_node: ", y, "\n");
        return;
    }
}

// The differences of the pages, or 2 if a page did not come.
fn differences(read: Target&, lines: u8[>..]&) -> i64 {
    var count = 0;
    for uri in PAGES {
        var want: u8[>..] = [];
        guard get(read, uri, want) else { format(lines, "pond_read gave no reply for ", uri, "\n"); return 2; }
        var fcgi: u8[>..] = [];
        var http: u8[>..] = [];
        let f = target("fcgi", read.port);
        let h = target("http", read.port);
        guard get(f, uri, fcgi) && get(h, uri, http) else { format(lines, "pond_node gave no reply for ", uri, "\n"); return 2; }
        for got, k in [fcgi[..], http[..]] {
            guard got != want && (k == 0 || http != fcgi) else { continue; }
            count++;
            let over = if k == 1 { "HTTP" } else if http == fcgi { "FastCGI and HTTP" } else { "FastCGI" };
            format(lines, "differs: ", uri, " over ", over, "\n");
            if uri == "/pond/entries.json" { report_entries(want, got, lines); } else { report_lines(want, got, lines); }
        }
    }
    return if count > 0 { 1 } else { 0 };
}

fn compare(read: Target&) {
    var lines: u8[>..] = [];
    var status = differences(read, lines);
    // A difference can be a save that pond_node did not read yet.
    if status != 0 {
        sleep_ms(RETRY_MS);
        lines.clear();
        status = differences(read, lines);
    }
    if status == 0 { lines.append("no difference\n"); }
    write_stdout(lines);
    flush_stdout();
    exit(status);
}

// bench

struct Sample { ns: i64, ok: bool }

thread_fn client(t: Target, uri: u8[..1024], n: i64) {
    for k in n {
        let t0 = clock_ns();
        var reply: u8[>..] = [];
        let ok = get(t, uri, reply) && starts_with(reply, "Status: 200");
        qput(Sample { ns: clock_ns() - t0, ok: ok });
    }
}

fn bench(t: Target&, uri: u8[:], clients: i64, n: i64) {
    guard uri.len < 1024 && clients >= 1 && n >= 1 else { fail("bench needs a uri, and 1 or more clients and requests"); }
    var u: u8[..1024] = [];
    u.append(uri);
    let t0 = clock_ns();
    var ids: i64[>..] = [];
    for k in clients { ids.push(thread_spawn(client, t, u, n)); }
    var ns: i64[>..] = [];
    var errors = 0;
    for k in clients * n {
        let s = qget<Sample>();
        ns.push(s.ns);
        if !s.ok { errors++; }
    }
    let wall = clock_ns() - t0;
    for id in ids { thread_wait(id); }
    sort(ns) { a, b => a < b };
    let total = clients * n;
    let us = 1000;
    print(t.kind, " ", uri, ": ", total, " requests from ", clients, " clients, ", errors, " errors, ",
          total * 1000000000 / wall, " requests/s, p50 ", ns[total / 2] / us, " us, p99 ",
          ns[total * 99 / 100] / us, " us, max ", ns[total - 1] / us, " us");
}

fn main() {
    let a = args();
    pond_no_sigpipe();
    if a.len == 6 && a[1] == "compare" {
        var t = target("cgi", number(a[5]));
        t.program.append(a[2]);
        t.pond.append(a[3]);
        t.template.append(a[4]);
        compare(t);
    } else if (a.len == 5 || a.len == 6) && a[1] == "get" && (a[2] == "fcgi" || a[2] == "http") {
        var reply: u8[>..] = [];
        let t = target(a[2], number(a[3]));
        guard request(t, if a.len == 6 { a[5] } else { "GET" }, a[4], reply) else { fail("no reply"); }
        write_stdout(reply);
        flush_stdout();
    } else if a.len == 7 && a[1] == "bench" && (a[2] == "fcgi" || a[2] == "http") {
        let t = target(a[2], number(a[3]));
        bench(t, a[4], number(a[5]), number(a[6]));
    } else if a.len == 9 && a[1] == "bench" && a[2] == "cgi" {
        var t = target("cgi", 0);
        t.program.append(a[3]);
        t.pond.append(a[4]);
        t.template.append(a[5]);
        bench(t, a[6], number(a[7]), number(a[8]));
    } else {
        fail(str("usage: pond_shadow compare <pond_read> <pond dir> <template> <port>\n",
                 "       pond_shadow get <fcgi|http> <port> <uri> [method]\n",
                 "       pond_shadow bench <fcgi|http> <port> <uri> <clients> <requests>\n",
                 "       pond_shadow bench cgi <pond_read> <pond dir> <template> <uri> <clients> <requests>"));
    }
}
