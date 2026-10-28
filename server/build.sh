#!/bin/sh
# Builds the save service from the committed C: on the Mac for the tests,
# and on OpenBSD for the server. `build.sh c` first makes pond_save.c again
# from pond_save.goose; that needs goose (GOOSE=path) and runs on the Mac.
set -eu
here=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" = c ]; then
    # From inside server/, so that the C names its source with no local path.
    (cd "$here" && "${GOOSE:-goose}" --standalone --include pond_verify.h -o pond_save.c pond_save.goose)
fi

# OpenBSD has libcrypto in base. The Mac has none for programs, so use Homebrew's.
crypto_cflags= crypto_libs=-lcrypto static=-static
if [ "$(uname)" = Darwin ]; then
    ssl=$(brew --prefix openssl)
    crypto_cflags="-I$ssl/include" crypto_libs="-L$ssl/lib -lcrypto" static=
fi

# A data stack reserves address space; 16 MB each is far more than a request needs.
cc -O2 $static -DGS_STACK_RESERVE='(16ull<<20)' -I"$here" $crypto_cflags \
    -o "$here/pond_save" "$here/pond_save.c" $crypto_libs -lm -pthread
