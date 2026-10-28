#!/bin/sh
# Builds the store's test programs from the committed C, on macOS, Linux and
# OpenBSD. `build.sh c` first makes store_tool.c and store_test.c again from
# the .goose files; that needs goose (GOOSE=path) and runs on the Mac.
set -eu
here=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" = c ]; then
    # From inside store/, so that the C names its source with no local path.
    (cd "$here" && "${GOOSE:-goose}" --standalone --include store_io.h -o store_tool.c store_tool.goose)
    (cd "$here" && "${GOOSE:-goose}" --standalone --include store_io.h -o store_test.c store_test.goose)
fi

# A data stack reserves address space. The segment is in one stack, so
# 16 MB each holds about 50,000 entries, and the stacks of all the threads
# of store_test stay in the 4 GB data limit of OpenBSD. STORE_FAULTS lets
# the crash tests kill a write.
for prog in store_tool store_test; do
    cc -O2 -DGS_STACK_RESERVE='(16ull<<20)' -DSTORE_FAULTS -I"$here" \
        -o "$here/$prog" "$here/$prog.c" -lm -pthread
done
