#!/bin/sh
# build.sh <tideSrc> <outDir>: copies Tide's src (init.luau, Client/, Server/, Shared/) to
# <outDir>/Tide. Defaults to ../src (this repository's library).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="${1:-$HERE/../../../src}"
OUT="$2"
[ -f "$SRC/init.luau" ] || { echo "tide: $SRC/init.luau not found (pass the tide src folder)" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$SRC" "$OUT/Tide"
echo "tide: built $OUT/Tide from $SRC"
