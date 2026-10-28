#!/bin/sh
# Measures the read path on this computer: pond_read as slowcgi runs it
# (one process for each request), then pond_node over FastCGI, on a log of
# 1,000 entries that pond_save saved. Each line gives the throughput, and
# the latency at the 50th and the 99th percentile.
# docs/store.md has the results. Needs openssl. Run build.sh first.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
node=
trap '[ -z "$node" ] || kill "$node" 2> /dev/null; rm -rf "$work"' EXIT
mkdir "$work/keys" "$work/entries"
openssl ecparam -name prime256v1 -genkey -noout -out "$work/phone.pem"
openssl pkey -in "$work/phone.pem" -pubout -outform DER | openssl base64 -A > "$work/keys/phone.pub"

# 1,000 entries over 2026, with a link, a made text and an interest.
i=0
while [ "$i" -lt 1000 ]; do
    printf '{"entry":{"date":"2026-%02d-%02d","interest":"biology","link":"https://example.org/paper/%d","made":"a note on paper %d","title":"Paper %d"},"id":"e%d","key":"phone","op":"put","rev":1,"v":1}' \
        $((i % 12 + 1)) $((i % 28 + 1)) "$i" "$i" "$i" "$i" > "$work/body"
    env -i REQUEST_METHOD=POST CONTENT_LENGTH="$(wc -c < "$work/body" | tr -d ' ')" POND_DIR="$work" \
        HTTP_SIGNATURE="$(openssl dgst -sha256 -sign "$work/phone.pem" < "$work/body" | openssl base64 -A)" \
        "$here/pond_save" < "$work/body" > /dev/null
    i=$((i + 1))
done
printf '<html>\n<main>\n<!-- pond:entries -->\n</main>\n</html>\n' > "$work/template.html"

"$here/pond_node" --pond "$work" --store "$work/store" --template "$work/template.html" --port 0 > "$work/node.out" 2> /dev/null &
node=$!
while ! grep -q "port" "$work/node.out" && kill -0 "$node" 2> /dev/null; do sleep 0.1; done
port=$(sed -n 's/^listening on 127.0.0.1 port //p' "$work/node.out")
"$here/pond_shadow" compare "$here/pond_read" "$work" "$work/template.html" "$port"

for clients in 1 8; do
    "$here/pond_shadow" bench cgi "$here/pond_read" "$work" "$work/template.html" /log/ "$clients" 100
    "$here/pond_shadow" bench fcgi "$port" /log/ "$clients" 2000
done
kill "$node"
wait "$node" 2> /dev/null || true
node=
