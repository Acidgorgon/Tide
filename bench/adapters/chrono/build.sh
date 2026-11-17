#!/bin/sh
# build.sh <chronoSrc> <outDir>: copies Chrono's src (Rojo layout: src/init.luau, Server/,
# Client/, Shared/) to <outDir>/chrono and adds what Strike's wally copy lacks (Shared/Warn.luau,
# Shared/Remotes/*.model.json, Shared/_CUSTOM_MODEL_REP) from shims/ when missing.
# Chrono itself is never vendored into this repository.
set -e
SRC="$1"
OUT="$2"
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC/init.luau" ] || { echo "chrono: $SRC/init.luau not found (pass the chrono src folder)" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$SRC" "$OUT/chrono"
[ -f "$OUT/chrono/Shared/Warn.luau" ] || cp "$HERE/shims/Warn.luau" "$OUT/chrono/Shared/Warn.luau"
[ -d "$OUT/chrono/Shared/Remotes" ] || cp -r "$HERE/shims/Remotes" "$OUT/chrono/Shared/Remotes"
[ -d "$OUT/chrono/Shared/_CUSTOM_MODEL_REP" ] || cp -r "$HERE/shims/_CUSTOM_MODEL_REP" "$OUT/chrono/Shared/_CUSTOM_MODEL_REP"
echo "chrono: built $OUT/chrono from $SRC"
