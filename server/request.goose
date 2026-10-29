// The checks of a save request of docs/protocol.md, shared by pond_save (the
// save on the server) and pond_node (the save on the desktop when the
// server is down), so that both refuse the same bodies with 400.

import std;
import os;
import json;

namespace request;

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

// The text of the 400 reply if body is not a valid save request, or "".
fn problem(body: u8[:]) -> u8[>..] {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(body, doc, decoded);
    guard root else { return str(err); }
    let v, v_ok = json::as_i64(json::member(root, "v"));
    let op, op_ok = json::as_string(json::member(root, "op"));
    let id, id_ok = json::as_string(json::member(root, "id"));
    let rev, rev_ok = json::as_i64(json::member(root, "rev"));
    let key, key_ok = json::as_string(json::member(root, "key"));
    let entry = json::member(root, "entry");
    guard v_ok && v == 1 && id_ok && is_name(id) && rev_ok && rev >= 1 && key_ok && is_name(key) else {
        return str("need v 1, id, rev and key");
    }
    let put_ok = op_ok && op == "put" && is_public_entry(entry);
    let remove_ok = op_ok && op == "remove" && !entry;
    guard put_ok || remove_ok else { return str("need op put with an entry, or op remove"); }
    return [];
}
