#!/usr/bin/env bash
# Build and run the GNOME clipboard / touchpad scrolling self-test against the live session.
# Needs: a logged-in GNOME session, python-gobject, and vendor/sunshine with the Lightpath patch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="${LIGHTPATH_SUNSHINE_SRC:-$ROOT/vendor/sunshine}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
g++ -std=c++23 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -DSUNSHINE_BUILD_MUTTER \
  -I"$HERE" -I"$SRC/src/platform/linux" -I"$SRC" $(pkg-config --cflags gio-2.0 gio-unix-2.0) \
  "$SRC/src/platform/linux/mutter_rd.cpp" "$HERE/selftest.cpp" \
  $(pkg-config --libs gio-2.0 gio-unix-2.0) -o "$TMP/selftest"
"$TMP/selftest" "$HERE/pc_app.py" "$TMP" 2>/dev/null
