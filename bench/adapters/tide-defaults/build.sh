#!/bin/sh
# Same build as adapters/tide (copies Tide's src into <outDir>/Tide).
exec "$(cd "$(dirname "$0")" && pwd)/../tide/build.sh" "$@"
