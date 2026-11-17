#!/usr/bin/env bash
# Build and install Lightpath's patched Sunshine as the Arch package "sunshine-lightpath".
#
#   host/build-sunshine.sh            # fetch upstream, apply patches, build, install
#   host/build-sunshine.sh --no-install
#
# Upstream commit: patches/sunshine/UPSTREAM_COMMIT. Patches: patches/sunshine/*.patch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/sunshine"
OUT="$ROOT/build"
COMMIT="$(cat "$ROOT/patches/sunshine/UPSTREAM_COMMIT")"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

log() { printf '\033[1;36m[lightpath]\033[0m %s\n' "$*"; }

if [[ ! -d "$SRC/.git" ]]; then
  log "Fetching Sunshine $COMMIT"
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/LizardByte/Sunshine.git
fi
if ! git -C "$SRC" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
  git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
fi

log "Applying patches"
git -C "$SRC" checkout -q --force --detach "$COMMIT"
git -C "$SRC" clean -qfdx -e third-party
for p in "$ROOT"/patches/sunshine/*.patch; do
  git -C "$SRC" -c user.name=lightpath -c user.email=lightpath@localhost am -q --keep-cr "$p"
done
git -C "$SRC" submodule update -q --init --recursive --depth 1 --jobs 8

log "Building (CUDA arch: native GPU)"
mkdir -p "$OUT"
cd "$ROOT/host/pkg"
LIGHTPATH_SUNSHINE_SRC="$SRC" PKGDEST="$OUT" BUILDDIR="$OUT/makepkg" \
  makepkg -f --noconfirm --nodeps --cleanbuild
PKG="$(ls -t "$OUT"/sunshine-lightpath-*.pkg.tar.zst | head -1)"
log "Built $PKG"

if ((INSTALL)); then
  sudo pacman -U --noconfirm "$PKG"
  systemctl --user daemon-reload
  systemctl --user restart app-dev.lizardbyte.app.Sunshine.service || true
  log "Installed and restarted Sunshine"
fi
