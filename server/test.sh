#!/bin/sh
# Runs the built pond_save and pond_read as slowcgi runs them (CGI variables,
# the body on stdin) against docs/protocol.md. Needs openssl to make keys and to sign.
# Run build.sh first.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/keys" "$work/entries"
fails=0

new_key() { # name: a private key, and its public key enrolled as keys/<name>.pub
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/$1.pem"
    openssl pkey -in "$work/$1.pem" -pubout -outform DER | openssl base64 -A > "$work/keys/$1.pub"
}
sign() { # key file: base64 DER signature of stdin
    openssl dgst -sha256 -sign "$1" | openssl base64 -A
}
post() { # body-file signature [length]: prints the Status line's code
    length=${3:-$(wc -c < "$1" | tr -d ' ')}
    env -i REQUEST_METHOD=POST CONTENT_LENGTH="$length" HTTP_SIGNATURE="$2" POND_DIR="$work" \
        "$here/pond_save" < "$1" | sed -n 's/^Status: \([0-9]*\).*/\1/p'
}
expect() { # name want got
    if [ "$2" = "$3" ]; then echo "pass: $1"; else echo "FAIL: $1: want $2, got $3"; fails=$((fails + 1)); fi
}
body() { # file text
    printf '%s' "$2" > "$work/$1"
}

new_key phone
new_key other

body put1 '{"v":1,"op":"put","id":"e1","rev":1,"key":"phone","entry":{"date":"2026-10-28","title":"1987 - IEEE Standard on Piezoelectricity"}}'
sig1=$(sign "$work/phone.pem" < "$work/put1")
expect "a new entry is saved" 201 "$(post "$work/put1" "$sig1")"
cmp -s "$work/put1" "$work/entries/e1.json" && expect "the file holds the exact body" same same || expect "the file holds the exact body" same different

expect "the same request again (a retry or a replay) changes nothing" 200 "$(post "$work/put1" "$sig1")"

body put1b '{"v":1,"op":"put","id":"e1","rev":1,"key":"phone","entry":{"date":"2026-10-28","title":"other"}}'
expect "a different body at the same rev is refused" 409 "$(post "$work/put1b" "$(sign "$work/phone.pem" < "$work/put1b")")"

body put2 '{"v":1,"op":"put","id":"e1","rev":2,"key":"phone","entry":{"date":"2026-10-28","title":"1987 - IEEE Standard on Piezoelectricity","link":"https://example.org/std"}}'
expect "a higher rev replaces the entry" 201 "$(post "$work/put2" "$(sign "$work/phone.pem" < "$work/put2")")"
expect "a replay of the old rev is refused" 409 "$(post "$work/put1" "$sig1")"
cmp -s "$work/put2" "$work/entries/e1.json" && expect "the old rev did not come back" same same || expect "the old rev did not come back" same different

body put3 '{"v":1,"op":"put","id":"e1","rev":3,"key":"phone","entry":{"date":"2026-10-28","title":"changed"}}'
expect "a signature from a key that is not enrolled as phone is refused" 403 "$(post "$work/put3" "$(sign "$work/other.pem" < "$work/put3")")"
expect "a signature of other bytes is refused" 403 "$(post "$work/put3" "$sig1")"
expect "no signature is refused" 403 "$(post "$work/put3" "")"
body ghost '{"v":1,"op":"put","id":"e1","rev":3,"key":"ghost","entry":{"date":"2026-10-28","title":"changed"}}'
expect "an unknown key id is refused" 403 "$(post "$work/ghost" "$(sign "$work/phone.pem" < "$work/ghost")")"
cmp -s "$work/put2" "$work/entries/e1.json" && expect "a refused request changes nothing" same same || expect "a refused request changes nothing" same different

body big "$(head -c 8193 /dev/zero | tr '\0' 'x')"
expect "a body over 8192 bytes is refused" 413 "$(post "$work/big" "")"

body fun '{"v":1,"op":"put","id":"e2","rev":1,"key":"phone","entry":{"date":"2026-10-28","title":"an album","fun":"loved it"}}'
expect "an entry with fun (private) is refused" 400 "$(post "$work/fun" "$(sign "$work/phone.pem" < "$work/fun")")"
for bad in \
    'unknown:{"date":"2026-10-28","title":"x","notice":"private"}' \
    'bad-domain:{"date":"2026-10-28","title":"x","domain":18}' \
    'bad-mode:{"date":"2026-10-28","title":"x","mode":"away"}' \
    'bad-kind:{"date":"2026-10-28","title":"x","kind":"secret"}' \
    'no-date:{"title":"x"}' \
    'number-title:{"date":"2026-10-28","title":7}' \
    'empty:{}'; do
    body bad '{"v":1,"op":"put","id":"e2","rev":1,"key":"phone","entry":'"${bad#*:}"'}'
    expect "an entry that is not public fields with valid values is refused (${bad%%:*})" 400 "$(post "$work/bad" "$(sign "$work/phone.pem" < "$work/bad")")"
done
body all '{"v":1,"op":"put","id":"e3","rev":1,"key":"phone","entry":{"date":"2026-10-28","domain":17,"interest":"biology","kind":"note","link":"https://arxiv.org/abs/2610.00001","made":"a note","mode":"take-part","slot":"morning","title":"a paper"}}'
expect "an entry with all the public fields is saved" 201 "$(post "$work/all" "$(sign "$work/phone.pem" < "$work/all")")"

body path '{"v":1,"op":"put","id":"../keys/phone","rev":1,"key":"phone","entry":{"date":"2026-10-28","title":"x"}}'
expect "an id that is not a plain name is refused" 400 "$(post "$work/path" "$(sign "$work/phone.pem" < "$work/path")")"

body remove '{"v":1,"op":"remove","id":"e1","rev":3,"key":"phone"}'
expect "a remove at a higher rev is saved" 201 "$(post "$work/remove" "$(sign "$work/phone.pem" < "$work/remove")")"
expect "after a remove, a replay of a put is refused" 409 "$(post "$work/put2" "$(sign "$work/phone.pem" < "$work/put2")")"

body put4 '{"v":1,"op":"put","id":"e1","rev":4,"key":"phone","entry":{"date":"2026-10-28","title":"after the lock"}}'
sig4=$(sign "$work/phone.pem" < "$work/put4")
perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\n"; sleep 2' "$work/entries/.lock" > "$work/held" &
holder=$!
while [ ! -s "$work/held" ]; do :; done
post "$work/put4" "$sig4" > "$work/put4.status" &
poster=$!
sleep 1
cmp -s "$work/remove" "$work/entries/e1.json" && expect "a request waits while another holds the entries lock" same same || expect "a request waits while another holds the entries lock" same different
wait "$holder" "$poster"
expect "the request saves after the lock is free" 201 "$(cat "$work/put4.status")"

got=$(env -i REQUEST_METHOD=GET POND_DIR="$work" "$here/pond_save" < /dev/null | sed -n 's/^Status: \([0-9]*\).*/\1/p')
expect "a GET is refused" 405 "$got"

# The read side, on a store of its own.
read=$work/read
mkdir -p "$read/entries"
get() { # uri [template]: the whole reply
    env -i REQUEST_METHOD=GET REQUEST_URI="$1" POND_DIR="$read" POND_TEMPLATE="${2:-$read/no-template}" "$here/pond_read"
}
has() { # name text: true if stdin has text
    if grep -qF -- "$2"; then expect "$1" yes yes; else expect "$1" yes no; fi
}
hasnt() { # name text: true if stdin does not have text
    if grep -qF -- "$2"; then expect "$1" no yes; else expect "$1" no no; fi
}
entry() { # id mtime entry-json: a put as pond_save keeps it
    printf '{"entry":%s,"id":"%s","key":"phone","op":"put","rev":1,"v":1}' "$3" "$1" > "$read/entries/$1.json"
    touch -t "$2" "$read/entries/$1.json"
}

expect "an empty store gives no entries" '{"entries":[]}' "$(get /pond/entries.json | tail -n 1)"
get /log/ | head -n 1 | has "an empty store gives a page" "Status: 200"
get /log/feed.xml | has "an empty store gives a feed" "</channel>"

entry old 202610270900 '{"date":"2026-10-27","title":"old"}'
entry morning 202610280800 '{"date":"2026-10-28","title":"morning"}'
entry evening 202610282000 '{"date":"2026-10-28","title":"evening"}'
order=$(get /pond/entries.json | tail -n 1 | grep -o '"id":"[a-z]*"' | tr -d '\n')
expect "entries.json is newest first: the date, then the time of the change" '"id":"evening""id":"morning""id":"old"' "$order"
order=$(get /log/ | grep -o '<h2>[a-z]*</h2>' | tr -d '\n')
expect "/log/ is newest first" '<h2>evening</h2><h2>morning</h2><h2>old</h2>' "$order"
order=$(get /log/feed.xml | grep -o '<title>[a-z]*</title>' | tr -d '\n')
expect "the feed is newest first" '<title>evening</title><title>morning</title><title>old</title>' "$order"
get /log/feed.xml | has "an item has an RFC 822 date" "<pubDate>Wed, 28 Oct 2026 00:00:00 +0000</pubDate>"

printf '%s' '{"id":"old","key":"phone","op":"remove","rev":2,"v":1}' > "$read/entries/old.json"
get /pond/entries.json | hasnt "a removed entry is not in entries.json" '"old"'
get /log/ | hasnt "a removed entry is not on /log/" ">old<"
get /log/feed.xml | hasnt "a removed entry is not in the feed" ">old<"

entry esc 202610290900 '{"date":"2026-10-29","link":"https://example.org/?a=1&b=\"2\"","made":"it'"'"'s <i>","title":"<script>x</script> & co"}'
get /log/ | has "a title is escaped for HTML" "<h2><a href=\"https://example.org/?a=1&amp;b=&quot;2&quot;\">&lt;script&gt;x&lt;/script&gt; &amp; co</a></h2>"
get /log/ | has "made is escaped for HTML" "<p>it&#39;s &lt;i&gt;</p>"
get /log/feed.xml | has "a title is escaped for XML" "<title>&lt;script&gt;x&lt;/script&gt; &amp; co</title>"
get /log/feed.xml | has "a link is escaped for XML" "<link>https://example.org/?a=1&amp;b=&quot;2&quot;</link>"
get /log/ | hasnt "no field goes out as raw HTML" "<script>"
entry js 202610290800 '{"date":"2026-10-29","link":"javascript:alert(1)","title":"js"}'
get /log/ | hasnt "a link that is not a web link is not a link" "javascript:"

entry private 202610290700 '{"date":"2026-10-29","experiment":"Feel it fully","fun":"loved it","notice":"hidden line","title":"private"}'
for page in /pond/entries.json /log/ /log/feed.xml; do
    got=$(get "$page" | grep -E -c 'experiment|Feel it fully|fun|loved it|notice|hidden line' || true)
    expect "no private field is in $page" 0 "$got"
done

printf '<html>\n<main>\n  <!-- pond:entries -->\n</main>\n<footer>end</footer>\n</html>\n' > "$read/template.html"
page=$(get /log/ "$read/template.html")
printf '%s' "$page" | has "the template is used" "<footer>end</footer>"
printf '%s' "$page" | hasnt "the marker line is replaced" "pond:entries"
expect "the entries are in place of the marker" '<main>|<article>' "$(printf '%s' "$page" | grep -A1 '^<main>$' | tr '\n' '|' | cut -d'|' -f1-2)"
expect "a missing template gives a plain page" '<h1>Log</h1>' "$(get /log/ | grep -o '<h1>Log</h1>')"

expect "an unknown path is not found" 404 "$(get /other | sed -n 's/^Status: \([0-9]*\).*/\1/p')"
got=$(env -i REQUEST_METHOD=POST REQUEST_URI=/log/ POND_DIR="$read" "$here/pond_read" < /dev/null | sed -n 's/^Status: \([0-9]*\).*/\1/p')
expect "a POST to the read service is refused" 405 "$got"

[ "$fails" = 0 ] && echo "all pass" || { echo "$fails failed"; exit 1; }
