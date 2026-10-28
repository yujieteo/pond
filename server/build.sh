#!/bin/sh
# Builds the save and read services, the daemon pond_node and its tool
# pond_shadow from the committed C: on the Mac for the tests, and on OpenBSD
# and Linux for the nodes. `build.sh c` first makes the C again from the
# .goose files; that needs goose (GOOSE=path) and runs on the Mac.
set -eu
here=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" = c ]; then
    # From inside server/, so that the C names its source with no local path.
    (cd "$here" && "${GOOSE:-goose}" --standalone --include pond_verify.h --include pond_lock.h -o pond_save.c pond_save.goose)
    (cd "$here" && "${GOOSE:-goose}" --standalone --include pond_read.h -o pond_read.c pond_read.goose)
    (cd "$here" && "${GOOSE:-goose}" --standalone --include pond_verify.h --include pond_read.h --include pond_net.h \
        --include pond_node.h --include pond_sync.h --include ../store/store_io.h -o pond_node.c pond_node.goose)
    (cd "$here" && "${GOOSE:-goose}" --standalone --include pond_net.h --include pond_spawn.h -o pond_shadow.c pond_shadow.goose)
fi

# OpenBSD has libcrypto in base, and the programs are static for the httpd
# chroot. The Mac has no libcrypto for programs, so use Homebrew's. On NixOS,
# run it in `nix-shell -p openssl`, which gives cc the place of libcrypto.
crypto_cflags='' crypto_libs=-lcrypto static=
case "$(uname)" in
OpenBSD) static=-static ;;
Darwin)
    ssl=$(brew --prefix openssl)
    crypto_cflags="-I$ssl/include" crypto_libs="-L$ssl/lib -lcrypto"
    ;;
esac

# A data stack reserves address space; 16 MB each is far more than a request needs.
cc -O2 $static -DGS_STACK_RESERVE='(16ull<<20)' -I"$here" $crypto_cflags \
    -o "$here/pond_save" "$here/pond_save.c" $crypto_libs -lm -pthread
cc -O2 $static -DGS_STACK_RESERVE='(16ull<<20)' -I"$here" \
    -o "$here/pond_read" "$here/pond_read.c" -lm -pthread
# The daemon holds the store in one data stack in each thread (docs/store.md).
cc -O2 $static -DGS_STACK_RESERVE='(16ull<<20)' -I"$here" -I"$here/../store" $crypto_cflags \
    -o "$here/pond_node" "$here/pond_node.c" $crypto_libs -lm -pthread
cc -O2 -DGS_STACK_RESERVE='(16ull<<20)' -I"$here" -o "$here/pond_shadow" "$here/pond_shadow.c" -lm -pthread
