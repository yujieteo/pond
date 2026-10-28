// The Pond read service: a CGI program behind OpenBSD httpd and slowcgi.
// It reads the entries that pond_save keeps and serves them, newest first:
// GET /pond/entries.json for the app, GET /log/ (the site template with the
// entries in it) and GET /log/feed.xml (RSS 2.0) for the public stream.
// It is a separate program from pond_save, so that it can run with no
// write access at all. render.goose makes the pages, and pond_node serves
// the same pages from the store. docs/protocol.md is the contract.

import std;
import os;
import render;

// pond_read.h: unveil and pledge on OpenBSD; the time of the last change of a file.
extern fn pond_sandbox(entries: const u8[:], template: const u8[:]) -> bool;
extern fn pond_mtime_ns(path: const u8[:]) -> i64;

// The entries that are there and not removed. A file that is not a valid
// put is left out, so that one damaged file does not stop the stream.
fn load(dir: u8[:]) -> render::Item[>..] {
    var items: render::Item[>..] = [];
    var names: u8[>..] = [];
    guard list_dir(dir, names) else { return items; }
    each_split(names, '\n') {
        guard ends_with(it, ".json");
        let path = str(dir, "/", it);
        var text: u8[>..] = [];
        guard read_file(path, text);
        let item, ok = render::item_of(text, pond_mtime_ns(path));
        if ok { items.push(copy(item)); }
    };
    return items;
}

// Newest first: the later date, then on the same date the later change.
fn newest_first(items: render::Item[:]) -> render::Item&[>..] {
    var order: render::Item&[>..] = [];
    for it in items { order.push(it); }
    stable_sort(order) { a, b =>
        let d = compare(a.date, b.date);
        d > 0 || (d == 0 && a.stamp > b.stamp)
    };
    return order;
}

fn main() {
    var dir: u8[>..] = [];
    if !env("POND_DIR", dir) { dir.append("/pond"); }
    var template_path: u8[>..] = [];
    if !env("POND_TEMPLATE", template_path) { template_path.append("/web/site/log/template.html"); }
    let entries_dir = str(dir, "/entries");
    var out: u8[>..] = [];
    guard pond_sandbox(entries_dir, template_path) else {
        render::format_reply(out, "500 Internal Server Error", "text/plain", "no sandbox\n");
        write_stdout(out);
        flush_stdout();
        return;
    }

    var method: u8[>..] = [];
    env("REQUEST_METHOD", method);
    var uri: u8[>..] = [];
    env("REQUEST_URI", uri);
    var items: render::Item[>..] = [];
    if method == "GET" { items = load(entries_dir); }
    render::reply(out, method, uri, template_path, newest_first(items));
    write_stdout(out);
    flush_stdout();
}
