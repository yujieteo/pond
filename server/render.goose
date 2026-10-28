// The read side of the log, shared by pond_read (CGI) and pond_node (the
// daemon), so that both serve the same bytes: GET /pond/entries.json for
// the app, GET /log/ (the site template with the entries in it) and
// GET /log/feed.xml (RSS 2.0) for the public stream. docs/protocol.md is
// the contract.

import std;
import os;
import json;

namespace render;

let SITE = "https://teoyujie.org/log/";
let MARKER = "<!-- pond:entries -->";

// One shown entry: its public fields, and the entry as JSON for the app.
// stamp orders the entries of one date: pond_read gives the time of the
// change of the file.
struct Item {
    id: u8[],
    rev: i64,
    date: u8[],
    stamp: i64,
    title: u8[],
    link: u8[],
    made: u8[],
    interest: u8[],
    json: u8[],
}

// s with the characters that HTML and XML give a meaning escaped, and with no
// control characters, which XML does not allow.
fn format_escaped(out: u8[>..]&, s: u8[:]) {
    for c in s {
        if c < ' ' && c != '\t' && c != '\n' && c != '\r' { continue; }
        else if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&quot;"); }
        else if c == '\'' { out.append("&#39;"); }
        else { out.push(c); }
    }
}

// Only a web link becomes a link, so that an entry cannot add a script.
fn is_web(link: u8[:]) -> bool {
    return starts_with(link, "https://") || starts_with(link, "http://");
}

fn string_of(n: json::Node?, key: u8[:]) -> const u8[:] {
    let s, ok = json::as_string(json::member(n, key));
    if ok { return s; }
    return "";
}

// The public fields of docs/protocol.md, and nothing else, as a JSON object
// with sorted keys. pond_save refuses other fields; this is a second guard.
fn format_public(out: u8[>..]&, n: json::Node?) {
    out.push('{');
    var first = true;
    for key in ["date", "domain", "interest", "kind", "link", "made", "mode", "slot", "title"] {
        let c = json::member(n, key);
        guard c else { continue; }
        let s, is_str = json::as_string(c);
        let i, is_int = json::as_i64(c);
        guard (key == "domain" && is_int) || (key != "domain" && is_str) else { continue; }
        if !first { out.push(','); }
        first = false;
        json::format_key(out, key);
        if is_str { json::format_string(out, s); } else { json::format_int(out, i); }
    }
    out.push('}');
}

// The item of a saved body, or false if the body is not a valid put. A
// remove, or a damaged body, is not shown, so that one bad entry does not
// stop the stream.
fn item_of(text: u8[:], stamp: i64) -> Item, bool {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    guard root else { return Item { .. }, false; }
    let op, op_ok = json::as_string(json::member(root, "op"));
    let id, id_ok = json::as_string(json::member(root, "id"));
    let rev, rev_ok = json::as_i64(json::member(root, "rev"));
    let entry = json::member(root, "entry");
    let date, date_ok = json::as_string(json::member(entry, "date"));
    let title, title_ok = json::as_string(json::member(entry, "title"));
    guard op_ok && op == "put" && id_ok && rev_ok && date_ok && title_ok else { return Item { .. }, false; }
    var out: u8[>..] = [];
    format_public(out, entry);
    return Item {
        id: id, rev: rev, date: date, stamp: stamp, title: title,
        link: string_of(entry, "link"), made: string_of(entry, "made"),
        interest: string_of(entry, "interest"), json: copy(out),
    }, true;
}

// One body at the top rev of an entry with siblings, for the conflicts list
// of the app: {"entry":{...},"op":"put"} with the public fields, or
// {"op":"remove"}.
fn format_sibling(out: u8[>..]&, text: u8[:]) {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    let entry = json::member(root, "entry");
    guard entry else { out.append("{\"op\":\"remove\"}"); return; }
    out.append("{\"entry\":");
    format_public(out, entry);
    out.append(",\"op\":\"put\"}");
}

// conflicts is the items of the conflicts list, from pond_node, or empty:
// then the reply has no conflicts list.
fn format_entries_json(out: u8[>..]&, order: Item&[:], conflicts: u8[:]) {
    out.append("{\"entries\":[");
    for it, k in order {
        if k > 0 { out.push(','); }
        out.append("{\"entry\":");
        out.append(it.json);
        out.append(",\"id\":");
        json::format_string(out, it.id);
        out.append(",\"rev\":");
        json::format_int(out, it.rev);
        out.push('}');
    }
    out.push(']');
    if conflicts.len > 0 { format(out, ",\"conflicts\":[", conflicts, "]"); }
    out.append("}\n");
}

// One <article> for each entry. The template's CSS gives the style.
fn format_articles(out: u8[>..]&, order: Item&[:]) {
    for it in order {
        out.append("<article>\n<time datetime=\"");
        format_escaped(out, it.date);
        out.append("\">");
        format_escaped(out, it.date);
        out.append("</time>\n<h2>");
        if is_web(it.link) {
            out.append("<a href=\"");
            format_escaped(out, it.link);
            out.append("\">");
            format_escaped(out, it.title);
            out.append("</a>");
        } else {
            format_escaped(out, it.title);
        }
        out.append("</h2>\n");
        if it.made.len > 0 {
            out.append("<p>");
            format_escaped(out, it.made);
            out.append("</p>\n");
        }
        if it.interest.len > 0 {
            out.append("<p class=\"interest\">");
            format_escaped(out, it.interest);
            out.append("</p>\n");
        }
        out.append("</article>\n");
    }
}

// The template with the articles in place of the marker line. With no
// template, or no marker in it, a plain page.
fn format_log(out: u8[>..]&, template: u8[:], order: Item&[:]) {
    var done = false;
    if template.len > 0 {
        var page: u8[>..] = [];
        each_split(template, '\n') {
            if !done && trim(it) == MARKER {
                format_articles(page, order);
                done = true;
            } else {
                page.append(it);
                page.push('\n');
            }
        };
        if done { out.append(page[..page.len - 1]); }
    }
    if !done {
        out.append("<!doctype html>\n<html lang=\"en\">\n<meta charset=\"utf-8\">\n");
        out.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
        out.append("<link rel=\"alternate\" type=\"application/rss+xml\" title=\"Log\" href=\"/log/feed.xml\">\n");
        out.append("<title>Log</title>\n<h1>Log</h1>\n");
        format_articles(out, order);
    }
}

// "2026-10-28" as an RFC 822 date for RSS, or false if it is not that form.
fn format_rfc822(out: u8[>..]&, date: u8[:]) -> bool {
    guard date.len == 10 && date[4] == '-' && date[7] == '-' else { return false; }
    for c, i in date {
        guard i == 4 || i == 7 || (c >= '0' && c <= '9') else { return false; }
    }
    let y, y_ok = parse_int(date[0..4]);
    let m, m_ok = parse_int(date[5..7]);
    let d, d_ok = parse_int(date[8..10]);
    guard y_ok && m_ok && d_ok && m >= 1 && m <= 12 && d >= 1 && d <= 31 else { return false; }
    // Sakamoto's method: 0 is Sunday.
    let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
    let yy = if m < 3 { y - 1 } else { y };
    let w = (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7;
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    format(out, days[w], ", ", date[8..10], " ", months[m - 1], " ", date[0..4], " 00:00:00 +0000");
    return true;
}

fn format_feed(out: u8[>..]&, order: Item&[:]) {
    out.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<rss version=\"2.0\">\n<channel>\n");
    format(out, "<title>Log</title>\n<link>", SITE, "</link>\n");
    out.append("<description>What I read, watched and made, newest first.</description>\n");
    for it in order {
        out.append("<item>\n<title>");
        format_escaped(out, it.title);
        out.append("</title>\n");
        if is_web(it.link) {
            out.append("<link>");
            format_escaped(out, it.link);
            out.append("</link>\n");
        }
        if it.made.len > 0 {
            out.append("<description>");
            format_escaped(out, it.made);
            out.append("</description>\n");
        }
        out.append("<guid isPermaLink=\"false\">");
        format_escaped(out, it.id);
        out.append("</guid>\n");
        var date: u8[>..] = [];
        if format_rfc822(date, it.date) { format(out, "<pubDate>", date, "</pubDate>\n"); }
        out.append("</item>\n");
    }
    out.append("</channel>\n</rss>\n");
}

fn format_reply(out: u8[>..]&, status: u8[:], content_type: u8[:], body: u8[:]) {
    format(out, "Status: ", status, "\r\nContent-Type: ", content_type, "\r\n\r\n", body);
}

// The whole CGI reply to a request: the Status and Content-Type lines, a
// blank line and the body. method and uri are the CGI REQUEST_METHOD and
// REQUEST_URI, order is the entries, newest first, and conflicts is for
// format_entries_json.
fn reply(out: u8[>..]&, method: u8[:], uri: u8[:], template_path: u8[:], order: Item&[:], conflicts: u8[:]) {
    guard method == "GET" else { format_reply(out, "405 Method Not Allowed", "text/plain", "use GET\n"); return; }
    let q = find(uri, "?");
    let path = if q >= 0 { uri[..q] } else { uri[..] };
    var body: u8[>..] = [];
    if path == "/pond/entries.json" {
        format_entries_json(body, order, conflicts);
        format_reply(out, "200 OK", "application/json", body);
    } else if path == "/log" || path == "/log/" {
        var template: u8[>..] = [];
        read_file(template_path, template);
        format_log(body, template, order);
        format_reply(out, "200 OK", "text/html; charset=utf-8", body);
    } else if path == "/log/feed.xml" {
        format_feed(body, order);
        format_reply(out, "200 OK", "application/rss+xml; charset=utf-8", body);
    } else {
        format_reply(out, "404 Not Found", "text/plain", "not found\n");
    }
}
