// The Pond save service: a CGI program behind OpenBSD httpd and slowcgi.
// It takes one signed change to one entry on POST /pond/entry, and keeps
// the newest revision of each entry as a file. docs/protocol.md is the
// contract; build.sh makes the C and the program.

import std;
import os;
import json;
import base64;

// pond_verify.h: ECDSA P-256 with SHA-256, through libcrypto.
extern fn pond_verify_p256(pub_der: const u8[:], msg: const u8[:], sig_der: const u8[:]) -> bool;
// pond_lock.h: an exclusive flock on a lock file, held until the process exits.
extern fn pond_lock(path: const u8[:]) -> bool;

let MAX_BODY = 8192;

fn reply(status: u8[:], text: u8[:]) {
    var out: u8[>..] = [];
    format(out, "Status: ", status, "\r\nContent-Type: text/plain\r\n\r\n", text, "\n");
    write_stdout(out);
    flush_stdout();
}

// An id or a key id is also a file name, so it has only these characters.
fn is_name(s: u8[:]) -> bool {
    guard s.len >= 1 && s.len <= 64 else { return false; }
    return all(s) { (it >= 'a' && it <= 'z') || (it >= 'A' && it <= 'Z') || (it >= '0' && it <= '9') || it == '-' };
}

// An entry has only the public fields of docs/protocol.md, with valid values.
// Any other field is refused, so that a fault in the phone cannot put
// private data (fun, a notice, an experiment) in a public file.
fn is_public_entry(n: json::Node?) -> bool {
    guard n else { return false; }
    match n.val {
        Obj => {},
        _ => { return false; },
    }
    var c = n.first;
    while c {
        let s, is_str = json::as_string(c);
        let i, is_int = json::as_i64(c);
        if c.key == "domain" {
            guard is_int && i >= 1 && i <= 17 else { return false; }
        } else if c.key == "mode" {
            guard is_str && (s == "home" || s == "live" || s == "take-part" || s == "make") else { return false; }
        } else if c.key == "kind" {
            guard is_str && (s == "media" || s == "note") else { return false; }
        } else {
            let known = c.key == "date" || c.key == "title" || c.key == "link" || c.key == "made" || c.key == "slot" || c.key == "interest";
            guard known && is_str else { return false; }
        }
        c .= c.next;
    }
    let date, date_ok = json::as_string(json::member(n, "date"));
    let title, title_ok = json::as_string(json::member(n, "title"));
    return date_ok && title_ok;
}

fn main() {
    var method: u8[>..] = [];
    env("REQUEST_METHOD", method);
    guard method == "POST" else { reply("405 Method Not Allowed", "use POST"); return; }

    var length_text: u8[>..] = [];
    env("CONTENT_LENGTH", length_text);
    let length, length_ok = parse_int(length_text);
    guard length_ok && length >= 0 else { reply("411 Length Required", "no Content-Length"); return; }
    guard length <= MAX_BODY else { reply("413 Content Too Large", "the body is over 8192 bytes"); return; }

    var body: u8[>..] = [];
    read_stdin(body);
    guard body.len == length else { reply("400 Bad Request", "the body is not Content-Length bytes"); return; }

    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(body, doc, decoded);
    guard root else { reply("400 Bad Request", err); return; }
    let v, v_ok = json::as_i64(json::member(root, "v"));
    let op, op_ok = json::as_string(json::member(root, "op"));
    let id, id_ok = json::as_string(json::member(root, "id"));
    let rev, rev_ok = json::as_i64(json::member(root, "rev"));
    let key, key_ok = json::as_string(json::member(root, "key"));
    let entry = json::member(root, "entry");
    guard v_ok && v == 1 && id_ok && is_name(id) && rev_ok && rev >= 1 && key_ok && is_name(key) else {
        reply("400 Bad Request", "need v 1, id, rev and key");
        return;
    }
    let put_ok = op_ok && op == "put" && is_public_entry(entry);
    let remove_ok = op_ok && op == "remove" && !entry;
    guard put_ok || remove_ok else { reply("400 Bad Request", "need op put with an entry, or op remove"); return; }

    var dir: u8[>..] = [];
    if !env("POND_DIR", dir) { dir.append("/pond"); }

    var sig_text: u8[>..] = [];
    env("HTTP_SIGNATURE", sig_text);
    var sig: u8[>..] = [];
    var pub_text: u8[>..] = [];
    var pub: u8[>..] = [];
    let signed = base64::decode(sig, sig_text)
        && read_file(str(dir, "/keys/", key, ".pub"), pub_text)
        && base64::decode(pub, trim(pub_text))
        && pond_verify_p256(pub, body, sig);
    guard signed else { reply("403 Forbidden", "no valid signature from an enrolled key"); return; }

    // The higher revision wins. The same body again is a retry, not a fault.
    // The lock makes the rev check and the write one step for concurrent requests.
    guard pond_lock(str(dir, "/entries/.lock")) else { reply("500 Internal Server Error", "cannot lock the entries"); return; }
    let path = str(dir, "/entries/", id, ".json");
    var old: u8[>..] = [];
    if read_file(path, old) {
        if old == body { reply("200 OK", "saved before"); return; }
        var old_doc: json::Node[>..] = [];
        var old_decoded: u8[>..] = [];
        let old_root, old_err = json::parse(old, old_doc, old_decoded);
        let old_rev, old_ok = json::as_i64(json::member(old_root, "rev"));
        guard old_ok else { reply("500 Internal Server Error", "the saved entry is damaged"); return; }
        guard rev > old_rev else { reply("409 Conflict", str("the server has rev ", old_rev)); return; }
    }
    guard write_file_atomic(path, body) else { reply("500 Internal Server Error", "cannot write the entry"); return; }
    reply("201 Created", "saved");
}
