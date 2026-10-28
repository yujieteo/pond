#!/bin/sh
# Runs the store tests: store_test (in one process), then the crash tests,
# which kill the writer process, and a race of writer processes. After each
# kill, store_tool verify checks the store against a model of the lines
# that the writer acknowledged. Run build.sh first.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tool=$here/store_tool
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
expect() { # name want got
    if [ "$2" = "$3" ]; then echo "pass: $1"; else echo "FAIL: $1: want $2, got $3"; fails=$((fails + 1)); fi
}

mkdir "$work/one"
"$here/store_test" "$work/one" || fails=$((fails + 1))

# The lines that the writer appends: puts of 20 ids with rising revs, old
# revs (refused), the line before again (a retry), and removes.
lines=$work/lines
awk 'BEGIN {
    for (k = 0; k < 8000; k++) {
        id = k % 20; rev = int(k / 20) + 1
        if (k % 13 == 5 && rev > 3) rev -= 3
        if (k % 19 == 7) { print last; continue }
        if (k % 17 == 3) last = sprintf("{\"id\":\"e%d\",\"key\":\"phone\",\"op\":\"remove\",\"rev\":%d,\"v\":1}", id, rev)
        else last = sprintf("{\"entry\":{\"date\":\"2026-10-%02d\",\"title\":\"line %d\"},\"id\":\"e%d\",\"key\":\"phone\",\"op\":\"put\",\"rev\":%d,\"v\":1}", k % 28 + 1, k, id, rev)
        print last
    }
}' > "$lines"
total=$(wc -l < "$lines" | tr -d ' ')

# The next line after the last acknowledged one, from the writer's output.
next_line() { # output-file current
    last=$(sed -n 's/^\([0-9]*\) .*/\1/p' "$1" | tail -n 1)
    if [ -n "$last" ]; then echo $((last + 1)); else echo "$2"; fi
}
verify() { # dir acked: counts a failure
    if ! "$tool" "$1" verify "$lines" "$2" > "$work/verify" 2>&1; then
        echo "after kill $kills:"; cat "$work/verify"; bad=$((bad + 1))
    fi
}

# Kills at random points in a write: the writer kills itself with SIGKILL
# when its writes reach a random number of bytes, in the middle of a record
# or at its end. Each 25th pass is a compaction instead: a compacted
# segment of the 20 ids is about 2,800 bytes. A kill counts only if the
# process died by SIGKILL (status 137), not if it ended before its budget.
dir=$work/crash
mkdir "$dir"
awk 'BEGIN { srand(20261028); for (i = 0; i < 2000; i++) print int(rand() * 600) + 1, int(rand() * 1000000) }' > "$work/points"
acked=0 passes=0 kills=0 compactions=0 bad=0
while [ "$kills" -lt 1000 ] && read -r point big; do
    status=0
    if [ $((passes % 25)) = 24 ]; then
        STORE_CRASH_AFTER=$((big % 3000 + 1)) "$tool" "$dir" compact > /dev/null 2>&1 &
        wait $! 2> /dev/null || status=$?
        [ "$status" != 137 ] || compactions=$((compactions + 1))
    else
        STORE_CRASH_AFTER=$point "$tool" "$dir" append-file "$lines" "$acked" > "$work/out" 2>&1 &
        wait $! 2> /dev/null || status=$?
        acked=$(next_line "$work/out" "$acked")
    fi
    passes=$((passes + 1))
    [ "$status" != 137 ] || kills=$((kills + 1))
    verify "$dir" "$acked"
    [ "$acked" -lt "$total" ] || { rm -r "$dir"; mkdir "$dir"; acked=0; }
done < "$work/points"
expect "$kills kills in a write at random points, in $passes passes ($compactions in a compaction): no acknowledged line lost or changed, no part of a record served" "1000 0" "$kills $bad"
"$tool" "$dir" check > "$work/check"
echo "note: $acked of $total lines acknowledged; $(cat "$work/check")"

# Kills from outside, at a random time.
dir=$work/async
mkdir "$dir"
awk 'BEGIN { srand(7); for (i = 0; i < 200; i++) printf "0.%03d\n", int(rand() * 60) + 1 }' > "$work/times"
acked=0 kills=0 bad=0
while [ "$kills" -lt 100 ] && read -r t; do
    "$tool" "$dir" append-file "$lines" "$acked" > "$work/out" 2>&1 &
    pid=$!
    sleep "$t"
    kill -9 "$pid" 2> /dev/null || true
    status=0
    wait "$pid" 2> /dev/null || status=$?
    acked=$(next_line "$work/out" "$acked")
    [ "$status" != 137 ] || kills=$((kills + 1))
    verify "$dir" "$acked"
    [ "$acked" -lt "$total" ] || { rm -r "$dir"; mkdir "$dir"; acked=0; }
done < "$work/times"
expect "$kills kills with SIGKILL at a random time: no acknowledged line lost or changed" "100 0" "$kills $bad"

# A race of writer processes on one store, each with the rev after the one
# it saw last, as the phone's outbox does after a 409.
dir=$work/race
mkdir "$dir"
for p in 1 2 3 4 5 6; do "$tool" "$dir" hammer 10 150 "p$p" > "$work/race.$p" & done
wait
created=$(cat "$work"/race.* | awk '{ n += $3 } END { print n }')
records=$("$tool" "$dir" check | awk '{ print $2 }')
expect "6 writer processes: each created change is in the segment once" "$created" "$records"
expect "6 writer processes: no rev goes back" ok "$("$tool" "$dir" revs 2>&1)"

if [ "$fails" = 0 ]; then echo "all pass"; else echo "$fails failed"; exit 1; fi
