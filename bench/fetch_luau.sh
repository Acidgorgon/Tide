#!/bin/sh
# Puts the Luau 0.700 sources the bench host is built from at bench/third_party/luau-0.700-src
# (gitignored). Uses $LUAU_SRC or Ripple's vendored copy if present (symlink), else downloads the
# `luau0-src` crate 0.16.0+luau700 from crates.io (MIT; the Luau 0.700 release sources).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/third_party/luau-0.700-src"
[ -d "$DEST/luau/VM" ] && exit 0
mkdir -p "$HERE/third_party"
for cand in "$LUAU_SRC" "$HERE/../../ripple/bench/third_party/luau-0.700-src"; do
	if [ -n "$cand" ] && [ -d "$cand/luau/VM" ]; then
		ln -sfn "$(cd "$cand" && pwd)" "$DEST"
		echo "linked $DEST -> $cand"
		exit 0
	fi
done
TMP=$(mktemp -d)
curl -sSL -o "$TMP/luau0.tar.gz" "https://crates.io/api/v1/crates/luau0-src/0.16.0+luau700/download"
tar xzf "$TMP/luau0.tar.gz" -C "$TMP"
mkdir -p "$DEST"
cp -r "$TMP"/luau0-src-*/luau "$DEST/luau"
cp "$TMP"/luau0-src-*/LICENSE "$DEST/LICENSE"
rm -rf "$TMP"
echo "downloaded Luau 0.700 sources to $DEST"
