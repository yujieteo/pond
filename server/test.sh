#!/bin/sh
# Runs the built pond_save as slowcgi runs it (CGI variables, the body on
# stdin) against docs/protocol.md. Needs openssl to make keys and to sign.
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

[ "$fails" = 0 ] && echo "all pass" || { echo "$fails failed"; exit 1; }
